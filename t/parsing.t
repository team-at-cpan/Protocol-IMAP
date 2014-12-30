use strict;
use warnings;

use Test::More;

my $handler = sub {
	my $code = shift;
	my $input = shift;

	my $json = JSON::MaybeXS->new(
		canonical => 1,
	);
	my %chars;
	@chars{split //, $input} = ();
	for my $ch (sort keys %chars) {
		for my $chunk (split /(\Q$ch\E)/, $input) {
			$code->($chunk);
		}
	}
};
done_testing;


