#!/usr/bin/env perl 
use strict;
use warnings;
use 5.010;
use Future;

my @handler;

sub skip_ws() { /\G\s*/gc; pop @handler if /\G(?=[^\s])/gc }

our $tasks;
our $data = { };
sub string($) {
	my $label = shift;
	my $started = 0;
	my $f = Future->new;
	my %spec; 
	$f->on_done(sub {
		my ($str) = @_;
		say "$label was: " . ($str // 'undef');
	});
	%spec = (
		code => sub {
			if(ref $_) {
				$f->done($label => $$_);
				return;
			}
			1 if /\G\s*/gc;
			if(/\GNIL/gc) {
				$f->done(undef);
				return;
			} elsif(/\G\{(\d+)\}/gc) {
				$spec{remaining} = $1 + 2;
				return;
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
						$f->done($label => $txt);
						return;
					}
				}
			} else {
				die "Not a string?: [" . substr($_, pos) . "]";
			}
		},
		completion => $f
	);
	push @$tasks, \%spec;
}
sub num($) {
	my $label = shift;
	my $started = 0;
	my $f = Future->new;
	my %spec; %spec = (
		code => sub {
			if(/\G(\d+)/gc) {
				$f->done($label => 0+$1);
				return;
			} else {
				die "Invalid number"
			}
		},
		completion => $f
	);
	push @$tasks, \%spec;
}

sub flag() {
	my $started = 0;
	my $f = Future->new;
	my %spec; %spec = (
		code => sub {
			if(/\G([a-z0-9\\]+)/gci) {
				say "Flag found: $1";
				$f->done($1);
				return;
			} else {
				die "Invalid flag"
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
sub sequence(&) {
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
				say "End of sequence";
				$tasks = delete $spec{old};
				say "Parent had " . @$tasks . " pending";
				$f->done;
				return;
			}
			say "Start of sequence";
			$spec{old} = $tasks;
			$tasks = [ @t, \%spec ];
			return;
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
			if($spec{old}) {
				$tasks = delete $spec{old};
				$f->done;
				return;
			}
			if(/\G([a-z0-9.]+)/gci) {
				my $k = $1;
				say "Found keyword: $k";
				die "Unknown keyword $k" unless exists $kw->{$k};
				skip_ws;
				$spec{old} = $tasks;
				my @t;
				{
					local $tasks = \@t;
					local $data = ($data->{$k} //= {});
					$kw->{$k}->();
				}
				{
					my $ff = Future->wait_all(map $_->{completion}, @t)->then(sub {
						my @rslt = map $_->get, @_;
						warn "Had @rslt for $k\n";
						# ($data->{$k}) = @rslt;
						Future->wrap
					});
					$ff->on_ready(sub { undef $ff });
				}
				$tasks = [ @t, \%spec ];
				return;
			} else { die "No keyword" }
		},
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
{
my @pending = (qq!(FLAGS (\\Seen Junk) INTERNALDATE "24-Feb-2012 17:41:19 +0000" RFC822.SIZE 1234 ENVELOPE ({31}\x0D\x0AFri, 24 Feb 2012 12:41:15 -0500 "[rt.cpan.org #72843] GET.pl example fails for reddit.com " (("Paul Evans via RT" NIL "bug-Net-Async-HTTP" "rt.cpan.org")) (("Paul Evans via RT" NIL "bug-Net-Async-HTTP" "rt.cpan.org")) ((NIL NIL "bug-Net-Async-HTTP" "rt.cpan.org")) ((NIL NIL "TEAM" "cpan.org")) ((NIL NIL "kiyoshi.aman" "gmail.com")) NIL "" "<rt-3.8.HEAD-10811-1330105275-884.72843-6-0\@rt.cpan.org>"))!);


use List::Util qw(min);
my $buffer;
my $required;
while(@pending) {
	$_ = (shift @pending) . "\n";
	if(defined($buffer)) {
		$buffer .= substr $_, 0, min($required, length($buffer) + length($_)), '';
	}
	while((pos($_) // 0) < length) {
		if(@$tasks) {
			$tasks->[0]->{code}->();
			if($tasks->[0]->{completion}->is_ready) {
	#			say "Future has completed";
				my $data = (shift @$tasks)->{data};
				skip_ws;
			} elsif(exists $tasks->[0]->{remaining}) {
				$required = $tasks->[0]->{remaining};
				say "Not ready yet - remaining: " . $required;
				# Remove everything we've processed so far
				substr $_, 0, pos($_), '';

				$buffer = substr $_, 0, min($required, length), '';
				if(length($buffer) == $required) {
					$tasks->[0]->{completion}->done($buffer);
					shift @$tasks;
					skip_ws;
				} else {
					last;
				}
	#		} else {
	#			say "Not a literal but not finished, probably nested tasks";
			}
		} else {
			say "Finished";
			last
		}
	}
}
use Data::Dumper; warn Dumper($data);

}