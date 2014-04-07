#!/usr/bin/env perl 
use strict;
use warnings;
use 5.010;
use Future;

my @handler;
my $string = sub {
	my $f = Future->new;
	my $txt;
	$f->on_done(sub {
		pop @handler;
	});
	my $started = 0;
	push @handler, sub {
		if(/\GNIL/gc) {
			print "String was empty\n";
			return $f->done(undef);
		}
		if($started) {
			while(/\G\\(["\\])/gc) {
				$txt .= $1;
			}
			if(/\G"/gc) {
				--$started;
				print "String was: $txt\n";
				return $f->done($txt);
			}
			if(/\G([^"\\]+)/gc) {
				$txt .= $1;
			}
		} else {
			if(/\G"/gc) {
				++$started;
				print "Starting string\n";
				$txt = '';
			}
		}
	};
	$f
};

my $int = sub {
	my $f = Future->new;
	my $v = '';
	$f->on_done(sub {
		pop @handler;
	});
	push @handler, sub {
		if(/\G(\d+)/gc) {
			say "Numeric";
			$v .= $1;
		}
		if(/\G\s|$/gc) {
			say "Hit end of string or whitespace";
			return $f->done(0+$v);
		}
	};
	$f
};

my %types = (
	flags => sub {
		print "Flag processing\n";
		my $started = 0;
		my @flags;
		push @handler, sub {
			if(/\G\(/gc) {
				die "Nested ()?" if $started++;
			}
			if(/\G\)/gc) {
				die "Unbalanced ()?" unless 1 == $started;
				shift @handler;
				print "Finished flags: " . join(',', @flags) . "\n";
			}
			if(/\G([a-z0-9.\\]+)/igc) {
				push @flags, $1;
				print "Adding flag $1\n";
			}
			if(/\G\s+/gc) {
				print "Whitespace\n";
			}
		}
	},
	internaldate => sub {
		my $f = $string->();
		$f->on_done(sub {
			say "Internal date: " . shift // 'undef';
		});
	},
	'rfc822.size' => sub {
		my $f = $int->();
		$f->on_done(sub {
			say "RFC822.SIZE: " . shift;
		});
	},
	envelope => sub {
		my $started = 0;
		if(/\G\s+/gc) {
			print "Whitespace\n";
		}
		if(/\G\(/gc) {
			die "Nested ()?" if $started++;
			say "In list";
		}
		if(/\G\)/gc) {
			die "Unbalanced ()?" unless 1 == $started;
			--$started;
		}

		my $f = $string->()->then(sub {
			say "Date: " . (shift // 'undef');
			if(/\G\s+/gc) {
				print "Whitespace\n";
			}
			$string->();
		})->then(sub {
			say "Subject: " . (shift // 'undef');
			if(/\G\s+/gc) {
				print "Whitespace\n";
			}
			$string->();
		})->then(sub {
		})
		$f->on_done(sub {
			say "Finished envelope";
		});
		$::xx_f = $f;
	},
);

$_ = '(FLAGS (\Seen Junk) INTERNALDATE "24-Feb-2012 17:41:19 +0000" RFC822.SIZE 1234)';
my $str = '(FLAGS (\Seen Junk) INTERNALDATE "24-Feb-2012 17:41:19 +0000" RFC822.SIZE 1234 ENVELOPE ("Fri, 24 Feb 2012 12:41:15 -0500" "[rt.cpan.org #72843] GET.pl example fails for reddit.com " (("Paul Evans via RT" NIL "bug-Net-Async-HTTP" "rt.cpan.org")) (("Paul Evans via RT" NIL "bug-Net-Async-HTTP" "rt.cpan.org")) ((NIL NIL "bug-Net-Async-HTTP" "rt.cpan.org")) ((NIL NIL "TEAM" "cpan.org")) ((NIL NIL "kiyoshi.aman" "gmail.com")) NIL "" "<rt-3.8.HEAD-10811-1330105275-884.72843-6-0@rt.cpan.org>"))';
my $depth = 0;
my $k;
for($str) {
	while((pos($_) // 0) < length) {
		if(@handler) {
			$handler[0]->($_);
		} else {
			if(/\G\(/gc) {
				++$depth;
				print "Depth now $depth\n";
			}
			if(/\G([a-z0-9.\\]+)/igc) {
				$k = lc $1;
				if(exists $types{$k}) {
					print "We have a handler for $k\n";
					$types{$k}->();
				} elsif(0) {
					print "Fuzzy match for $k\n";
				} else {
					die "Not found: $k" unless exists $types{$k};
				}
				print ":: $k\n";
			}
			if(/\G\)/gc) {
				--$depth;
				print "Depth now $depth\n";
				unless($depth) {
					print "Finished\n";
				}
			}
			if(/\G\s+/gc) {
				print "Whitespace\n";
			}
		}
	}
}
exit;

=pod


	[
		date        => 'string',
		subject     => 'string',
		from        => 'address',
		sender      => 'address',
		reply_to    => 'address',
		to          => 'address',
		cc          => 'address',
		bcc         => 'address',
		in_reply_to => 'string',
		message_id  => 'string',
	]

fetch response:


keyword:
 'TEXT', whitespace, content

string:
 "..." / NIL / {N}\x0D\x0A...literal...

flag:
 [a-z0-9.\\]+

addresslist:
 name, ws, smtp, ws, mailbox, ws, host

=cut

