#!/usr/bin/env perl 
use strict;
use warnings;
use 5.010;

my @handler;

sub skip_ws() { /\G\s+/gc; pop @handler if /\G(?=[^\s])/gc }

sub string($) {
	my $started = 0;
	if(/\GNIL/gc) {
		say "Empty string";
		pop @handler;
		return undef;
	} elsif(/\G\{(\d+)\}/gc) {
		die "Literal - would need $1 bytes";
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
				pop @handler;
				return $txt;
			}
		}
	} else {
		die "Not a string?";
	}
}

sub num($) {
	if(/\G(\d+)/gc) {
		pop @handler;
		return $1
	} else { die "Invalid number?" }
}

sub flag() {
	if(/\G([a-z0-9\\]+)/gci) {
		say "Flag: $1";
		pop @handler;
		return $1
	} else { die "Invalid flag info?" }
}

sub potential_keywords($) {
	my $kw = shift;
	if(/\G([a-z0-9.]+)/gci) {
		say "Found keyword: $1";
		die "Unknown keyword $1" unless exists $kw->{$1};
		skip_ws;
		pop @handler;
		return $kw->{$1}->();
	} else { die "No keyword" }
}

sub group(&) {
	my $code = shift;
	if(/\G\(/gc) {
		say "Start of list";
		$code->();
		if(/\G\)/gc) {
			say "End of list";
			pop @handler;
			return;
		} else { die ") not found" }
	} else { die "( not found" }
}

sub list(&) {
	my $code = shift;
	if(/\G\(/gc) {
		say "Start of list";
		while(1) {
			$code->();
			skip_ws;
			if(/\G\)/gc) {
				say "End of list";
				pop @handler;
				return;
			}
		}
	} else {
		die "( not found"
	}
}

sub addresslist($) {
	if(/\GNIL/gc) {
		pop @handler;
		return;
	}
	list {
		group {
			string 'name';
			skip_ws;
			string 'smtp';
			skip_ws;
			string 'mailbox';
			skip_ws;
			string 'host';
		}
	}
}

my $str = '(FLAGS (\Seen Junk) INTERNALDATE "24-Feb-2012 17:41:19 +0000" RFC822.SIZE 1234 ENVELOPE ("Fri, 24 Feb 2012 12:41:15 -0500" "[rt.cpan.org #72843] GET.pl example fails for reddit.com " (("Paul Evans via RT" NIL "bug-Net-Async-HTTP" "rt.cpan.org")) (("Paul Evans via RT" NIL "bug-Net-Async-HTTP" "rt.cpan.org")) ((NIL NIL "bug-Net-Async-HTTP" "rt.cpan.org")) ((NIL NIL "TEAM" "cpan.org")) ((NIL NIL "kiyoshi.aman" "gmail.com")) NIL "" "<rt-3.8.HEAD-10811-1330105275-884.72843-6-0@rt.cpan.org>"))';
#my $str = '(FLAGS (\Seen Junk) INTERNALDATE "24-Feb-2012 17:41:19 +0000" RFC822.SIZE 1234 ENVELOPE ({31}
#Fri, 24 Feb 2012 12:41:15 -0500 "[rt.cpan.org #72843] GET.pl example fails for reddit.com " (("Paul Evans via RT" NIL "bug-Net-Async-HTTP" "rt.cpan.org")) (("Paul Evans via RT" NIL "bug-Net-Async-HTTP" "rt.cpan.org")) ((NIL NIL "bug-Net-Async-HTTP" "rt.cpan.org")) ((NIL NIL "TEAM" "cpan.org")) ((NIL NIL "kiyoshi.aman" "gmail.com")) NIL "" "<rt-3.8.HEAD-10811-1330105275-884.72843-6-0@rt.cpan.org>"))';

sub run_stack {
}

eval {
	for($str) {
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
						string      'date'; skip_ws;
						string      'subject'; skip_ws;
						addresslist 'from'; skip_ws;
						addresslist 'sender'; skip_ws;
						addresslist 'reply_to'; skip_ws;
						addresslist 'to'; skip_ws;
						addresslist 'cc'; skip_ws;
						addresslist 'bcc'; skip_ws;
						string      'in_reply_to'; skip_ws;
						string      'message_id';
					}
				},
				'INTERNALDATE'   => sub { string 'internaldate' },
				'UID'            => sub { num 'uid' },
				'RFC822.SIZE'    => sub { num 'size' },
			}
		};
		run_stack();
	}
	1
} or do {
	my $err = $@;
	my $remaining = substr $str, pos($str);
	warn "Had $err\nwith remaining: [$remaining]\n";
};

__END__

=pod

stack of active tasks
 ...
  ...
   pending items

Our current task has zero or more pending items. When the pending count drops to zero
we've finished the task.

list
 group
  string
  string
  num


string:
 * 

If a streaming handler is provided:
 * ->on_chunk($text)...
 * ->done()

$text will be '' if we had an empty string or literal, undef if we had NIL

Otherwise, ->done will be called with the content:
* NIL => undef
* empty string => ''
* literal/string => '...'

=cut

