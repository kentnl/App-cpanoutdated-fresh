use 5.008;    # utf8
use strict;
use warnings;
use utf8;

package App::cpanoutdated::fresh;

our $VERSION = '0.001000';

# ABSTRACT: Indicate out-of-date modules by walking the metacpan releases backwards

# PODNAME: cpan-outdated-fresh

our $AUTHORITY = 'cpan:KENTNL'; # AUTHORITY

use Carp qw( croak );
use Moo qw( has );
use MooX::Lsub qw( lsub );
use Getopt::Long;
use Search::Elasticsearch;
use Search::Elasticsearch::Scroll;
use Module::Metadata;
use Path::ScanINC;
use Pod::Usage qw( pod2usage );
use version;

has ua => ( is => 'ro', predicate => 'has_ua' );
lsub trace => sub { undef };
lsub es => sub {
  my ($self) = @_;
  my %args = (
    nodes            => 'api.metacpan.org',
    cxn_pool         => 'Static::NoPing',
    send_get_body_as => 'POST',

    #    trace_to         => 'Stderr',
  );
  if ( $self->has_ua ) {
    $args{handle} = $self->ua;
  }
  if ( $self->trace ) {
    $args{trace_to} = 'Stderr';
  }
  return Search::Elasticsearch->new(%args);
};
lsub _sort       => sub { 'desc' };
lsub scroll_size => sub { 1000 };
lsub age         => sub { '7d' };
lsub age_seconds => sub {
  my ($self) = @_;
  my $table = {
    'm' => (60),
    'h' => ( 60 * 60 ),
    's' => (1),
    'd' => ( 24 * 60 * 60 ),
    'w' => ( 7 * 24 * 60 * 60 ),
    'M' => ( 31 * 24 * 60 * 60 ),
    'Y' => ( 365 * 24 * 60 * 60 ),
  };
  return $self->age + 0 unless my ( $time, $multiplier ) = $self->age =~ /\A(\d+)([[:lower:]])\z/msx;
  if ( not exists $table->{$multiplier} ) {
    croak("Unknown time multiplier <$multiplier>");
  }
  return $time * $table->{$multiplier};
};
lsub min_timestamp => sub {
  my ($self) = @_;
  return time() - $self->age_seconds;
};
lsub developer    => sub { undef };
lsub all_versions => sub { undef };
lsub authorized   => sub { 1 };
lsub _inc_scanner => sub { Path::ScanINC->new() };

sub _mk_scroll {
  my ($self) = @_;

  my $body = {
    query => {
      range => {
        'stat.mtime' => {
          gte => $self->min_timestamp,
        },
      },
    },
  };
  if ( not $self->developer or $self->authorized ) {
    $body->{filter} ||= {};
    $body->{filter}->{term} ||= {};
  }
  if ( not $self->developer ) {
    $body->{filter}->{term}->{'maturity'} = 'released';
  }
  if ( $self->authorized ) {
    $body->{filter}->{term}->{'authorized'}        = 'true';
    $body->{filter}->{term}->{'module.authorized'} = 'true';
  }

  my $fields = [
    qw(
      name distribution path
      stat.mtime module author
      authorized date indexed
      directory maturity release
      status version
      ),
  ];

  my %scrollargs = (
    scroll => '5m',
    index  => 'v0',
    type   => 'module',
    size   => $self->scroll_size,
    body   => $body,
    fields => $fields,
  );
  if ( not $self->_sort ) {
    $scrollargs{'search_type'} = 'scan';
  }
  else {
    $body->{sort} = { 'stat.mtime' => $self->_sort };
  }
  return $self->es->scroll_helper(%scrollargs);
}

sub _check_fresh {
  my ( $self, $data_hash, $module ) = @_;
  return unless $module->{indexed} and $module->{authorized} and $module->{version};

  my (@parts) = split /::/msx, $module->{name};
  $parts[-1] .= '.pm';

  my $file = $self->_inc_scanner->first_file(@parts);
  return unless $file;

  my $mm = Module::Metadata->new_from_file($file);
  return if not $mm;

  my $v = version->parse( $module->{version} );

  if ( $mm->version >= $v ) {
    return;
  }

  return {
    name      => $module->{name},
    cpan      => $v->stringify,
    release   => $data_hash->{release},
    installed => $mm->version->stringify,
    meta      => $data_hash,
  };

}

sub _get_next {
  my ( $self, $scroll ) = @_;
  if ( not exists $self->{stash_cache} ) {
    $self->{stash_cache} = {};
  }
  my $stash_cache = $self->{stash_cache};
  while ( my $scroll_result = $scroll->next ) {
    return unless $scroll_result;
    my $data_hash = $scroll_result->{'_source'} || $scroll_result->{'fields'};
    my $cache_key = $data_hash->{distribution};
    if ( $self->all_versions ) {
      $cache_key = $data_hash->{release};
    }

    #  pp($data_hash);
    next if exists $stash_cache->{$cache_key};
    next if not $self->developer and 'developer' eq $data_hash->{maturity};

    next if $data_hash->{path} =~ /\Ax?t\//msx;
    next unless $data_hash->{path} =~ /\.pm\z/msx;
    next unless $data_hash->{module};
    next unless @{ $data_hash->{module} };
    for my $module ( @{ $data_hash->{module} } ) {
      my $fresh_data = $self->_check_fresh( $data_hash, $module );
      next unless $fresh_data;
      $stash_cache->{$cache_key} = 1;
      return $fresh_data;
    }
    $stash_cache->{$cache_key} = 1;
  }
  return;
}

sub new_from_command {
  my ( $class, $defaults ) = @_;
  Getopt::Long::Configure('bundling');
  $defaults ||= {};
  my ( $help, $man );
  Getopt::Long::GetOptions(
    'age|a=s' => sub {
      my ( undef, $value ) = @_;
      $defaults->{age} = $value;
    },
    'develop|devel|dev!' => sub {
      my ( undef, $value ) = @_;
      if ($value) {
        $defaults->{developer} = 1;
        return;
      }
      $defaults->{developer} = undef;
    },
    'authorized|authed!' => sub {
      my ( undef, $value ) = @_;
      if ($value) {
        $defaults->{authorized} = 1;
      }
      else {
        $defaults->{authorized} = undef;
      }
    },
    'help|h|?' => \$help,
    'man'      => \$man,
  ) or do { $help = 1 };
  if ( $help or $man ) {
    if ($help) {
      return pod2usage( { -exitval => 1, }, );
    }
    return pod2usage( { -exitval => 1, -verbose => 2, }, );
  }
  return $class->new(%{$defaults});
}

sub run {
  my ($self) = @_;
  my $iterator = $self->_mk_scroll;
  while ( my $result = $self->_get_next($iterator) ) {
    printf "%s\@%s\n", $result->{name}, $result->{cpan};
  }
  return 0;
}

sub run_command {
  my ($class) = @_;
  return $class->new_from_command->run();
}

no Moo;







































1;

__END__

=pod

=encoding UTF-8

=head1 NAME

cpan-outdated-fresh - Indicate out-of-date modules by walking the metacpan releases backwards

=head1 VERSION

version 0.001000

=head1 SYNOPSIS

  cpan-outdated-fresh [--args]

    --age  TIMESPEC  The maximum age for a release (default: 7d)
     -a    TIMESPEC

    --develop        Include development releases in output
    --devel
    --dev
    
    --no-develop     Exclude development releases from output (default)
    --no-devel
    --no-dev

    --authorized     Show only authorized releases in output (default)
    --authed
    
    --no-authorized  Show even unauthorized releases in output
    --no-authed

=head2 TIMESPEC

  <int seconds>
  <int><multiplier> 

=head3 multipliers

  s = second
  m = minute
  h = hour
  d = day
  w = 7 days
  M = 31 days
  Y = 365 days

=head1 AUTHOR

Kent Fredric <kentfredric@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2014 by Kent Fredric <kentfredric@gmail.com>.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
