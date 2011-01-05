use strict;
use warnings;

use Test::More tests => 13;
use Protocol::IMAP;

my $imap = new_ok('Protocol::IMAP');
ok($imap->STATE_HANDLERS, 'have state handlers');
like($_, qr/^on_/, "state handler $_ has on_ prefix") for $imap->STATE_HANDLERS;
can_ok($imap, $_) for qw{debug state write new};

