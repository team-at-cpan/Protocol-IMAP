#!/usr/bin/env perl 
use strict;
use warnings;
use 5.010;
use Future;

my @handler;

sub skip_ws() { /\G\s+/gc; pop @handler if /\G(?=[^\s])/gc }

our $tasks;
sub string($) {
	my $started = 0;
	my $f = Future->new;
	my %spec; %spec = (
		code => sub {
			if(/\GNIL/gc) {
				say "Empty string";
				$f->done(undef);
				return;
			} elsif(/\G\{(\d+)\}/gc) {
				$spec{remaining} = $1;
				return;
#				die "Literal - would need $1 bytes";
			} elsif(/\G"/gc) {
				my $txt = '';
				while(1) {
					while(/\G\\(["\\])/gc) {
						$txt .= $1;
					}
					if(/\G([^"\\]+)/gc) {
						$txt .= $1;
					}
					if(/\G"/gc) {
						say "String was: $txt";
						$f->done($txt);
						return;
					}
				}
			} else {
				die "Not a string?";
			}
		},
		completion => $f
	);
	push @$tasks, \%spec;
}

my @pending;
sub group(&) {
	my $code = shift;
	my @t;
	{
		local $tasks = \@t;
		$code->();
	}
	my $f = Future->new;
	my %spec; %spec = (
		code => sub {
			if($spec{old}) {
				if(/\G\)/gc) {
					say "End of group";
					$tasks = delete $spec{old};
					say "Parent had " . @$tasks . " pending";
					$f->done;
					return;
				} else {
					die ") not found"
				}
			}
			if(/\G\(/gc) {
				say "Start of group";
				$spec{old} = $tasks;
				$tasks = [ @t, \%spec ];
				return;
			} else {
				die "( not found"
			}
		},
		completion => $f,
	);
	push @$tasks, \%spec;
}

sub list(&) {
	my $code = shift;
	my @t;
	{
		local $tasks = \@t;
		$code->();
	}
	my $f = Future->new;
	my %spec; %spec = (
		code => sub {
			say "In list process";
			if($spec{old}) {
				if(/\G\)/gc) {
					say "End of list";
					$tasks = $spec{old};
					$f->done;
					return;
				} else {
					say "Not finished yet: @t";
					skip_ws;
					@t = ();
					{
						local $tasks = \@t;
						$code->();
					}
					$tasks = [ @t, \%spec ];
					return;
				}
			}
			if(/\G\(/gc) {
				say "Start of list";
				$spec{old} = $tasks;
				$tasks = [ @t, \%spec ];
				return;
			} else {
				die "( not found"
			}
		},
		completion => $f,
	);
	push @$tasks, \%spec;
}

list {
	group {
		list {
			group {
				string 'x';
				string 'y';
			};
		};
	};
};

$_ = '(((("one" "two") ("three" {5}
12345) ({3}
abc "six"))))';
while(1) {
	if(@$tasks) {
		$tasks->[0]->{code}->();
		if($tasks->[0]->{completion}->is_ready) {
			say "Future has completed";
			shift @$tasks;
			skip_ws;
		} elsif(exists $tasks->[0]->{remaining}) {
			my $required = $tasks->[0]->{remaining};
			say "Not ready yet - remaining: " . $required;
			my $re = "\n(.{${required}})";
			/\G$re/gc or die 'RE failed';
			shift @$tasks;
			skip_ws;
		} else {
			say "Not a literal but not finished, probably nested tasks";
		}
	} else {
		say "Finished";
		last
	}
}

