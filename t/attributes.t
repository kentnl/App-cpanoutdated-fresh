
use strict;
use warnings;

use Test::More;
use Test::Fatal qw( exception );
use App::cpanoutdated::fresh;

# FILENAME: attributes.t
# CREATED: 08/30/14 22:00:04 by Kent Fredric (kentnl) <kentfredric@gmail.com>
# ABSTRACT: Test attributs

my $instance => App::cpanoutdated::fresh->new();

sub attr {
  my ( $name ) = @_;
  my $value;
  is ( exception { $value = $instance->$name(); 1 }, undef, "Get attribute $name"); 
}

attr('trace');
attr('es');
attr('_sort');
attr('scroll_size');
attr('age');
attr('age_seconds');
attr('min_timestamp');
attr('developer');
attr('all_versions');
attr('authorized');
attr('_inc_scanner');

done_testing;


