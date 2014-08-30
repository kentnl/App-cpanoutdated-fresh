
use strict;
use warnings;

use Test::More 0.96;
use Test::Fatal qw( exception );

# FILENAME: constructors.t
# CREATED: 08/30/14 21:51:39 by Kent Fredric (kentnl) <kentfredric@gmail.com>
# ABSTRACT: Test constructing the internal object

use App::cpanoutdated::fresh;

sub canspawn {
  my ( @args ) = @_;
  local @ARGV = @args;
  is(exception{ App::cpanoutdated::fresh->new_from_command() }, undef );
}

subtest 'noargs' => sub {

    canspawn;

};
done_testing;


