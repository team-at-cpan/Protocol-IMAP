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
sub num($) {
	my $started = 0;
	my $f = Future->new;
	my %spec; %spec = (
		code => sub {
			if(/\G(\d+)/gc) {
				$f->done(0+$1);
				return;
			} else {
				die "Invalid number"
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

sub addresslist($) {
	my $f = Future->new;
	my %spec; %spec = (
		code => sub {
			if(/\GNIL/gc) {
				$f->done(undef);
				return;
			}
			my @t;
			{
				local $tasks = \@t;
				list {
					group {
						string 'name';
						string 'smtp';
						string 'mailbox';
						string 'host';
					}
				}
			}
			$tasks = \@t;
		},
		completion => $f,
	);
	push @$tasks, \%spec;
}

sub potential_keywords($) {
	my $kw = shift;
	my $f = Future->new;
	my %spec; %spec = (
		code => sub {
			if(/\G([a-z0-9.]+)/gci) {
				my $k = $1;
				say "Found keyword: $k";
				die "Unknown keyword $k" unless exists $kw->{$k};
				skip_ws;
				$tasks = [];
				$kw->{$k}->();
				return;
			} else { die "No keyword" }
		}
		completion => $f,
	);
	push @$tasks, \%spec;
}

list {
	# We expect to see zero or more of these, order doesn't seem
	# to be too important either.
	potential_keywords {
		# We can have zero or more flags
		'FLAGS'          => sub {
			list { flag }
		},
		'BODY'           => sub { },
		'BODYSTRUCTURE'  => sub { },
		'ENVELOPE'       => sub {
			group {
				string      'date';
				string      'subject';
				addresslist 'from';
				addresslist 'sender';
				addresslist 'reply_to';
				addresslist 'to';
				addresslist 'cc';
				addresslist 'bcc';
				string      'in_reply_to';
				string      'message_id';
			}
		},
		'INTERNALDATE'   => sub { string 'internaldate' },
		'UID'            => sub { num 'uid' },
		'RFC822.SIZE'    => sub { num 'size' },
	}
};

#$_ = '(((("one" "two") ("three" {5}
#12345) ({3}
#abc "six"))))';
$_ = '(FLAGS (\Seen Junk) INTERNALDATE "24-Feb-2012 17:41:19 +0000" RFC822.SIZE 1234 ENVELOPE ("Fri, 24 Feb 2012 12:41:15 -0500" "[rt.cpan.org #72843] GET.pl example fails for reddit.com " (("Paul Evans via RT" NIL "bug-Net-Async-HTTP" "rt.cpan.org")) (("Paul Evans via RT" NIL "bug-Net-Async-HTTP" "rt.cpan.org")) ((NIL NIL "bug-Net-Async-HTTP" "rt.cpan.org")) ((NIL NIL "TEAM" "cpan.org")) ((NIL NIL "kiyoshi.aman" "gmail.com")) NIL "" "<rt-3.8.HEAD-10811-1330105275-884.72843-6-0@rt.cpan.org>"))';
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

