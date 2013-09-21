use strict;
use warnings;
use Protocol::IMAP::FetchResponseParser;
use Try::Tiny;

use Test::More;

my @cases = ({
	description => 'flags only',
	input => <<'EOF',
(FLAGS (\Seen))
EOF
	result => {
		flags => ['\\Seen']
	}
}, {
	description => 'flags, internaldate',
	input => <<'EOF',
(FLAGS (\Seen) INTERNALDATE "2013-01-01 14:24:00")
EOF
	result => {
		flags => ['\\Seen'],
		internaldate => '2013-01-01 14:24:00'
	}
}, {
	description => 'flags, internaldate, size',
	input => <<'EOF',
(FLAGS (\Seen) INTERNALDATE "2013-01-01 14:24:00" RFC822.SIZE 1024)
EOF
	result => {
		flags => ['\\Seen'],
		internaldate => '2013-01-01 14:24:00',
		'rfc822.size' => 1024,
	}
}, {
	description => 'first sample from RFC3501',
	input => <<'EOF',
(FLAGS (\Seen) INTERNALDATE "17-Jul-1996 02:44:25 -0700" RFC822.SIZE 4286 ENVELOPE ("Wed, 17 Jul 1996 02:23:25 -0700 (PDT)" "IMAP4rev1 WG mtg summary and minutes" (("Terry Gray" NIL "gray" "cac.washington.edu")) (("Terry Gray" NIL "gray" "cac.washington.edu")) (("Terry Gray" NIL "gray" "cac.washington.edu")) ((NIL NIL "imap" "cac.washington.edu")) ((NIL NIL "minutes" "CNRI.Reston.VA.US") ("John Klensin" NIL "KLENSIN" "MIT.EDU")) NIL NIL "<B27397-0100000@cac.washington.edu>") BODY ("TEXT" "PLAIN" ("CHARSET" "US-ASCII") NIL NIL "7BIT" 3028 92))
EOF
	result => {
		flags => ['\\Seen'],
		internaldate => "17-Jul-1996 02:44:25 -0700",
		'rfc822.size' => 4286,
		envelope => {
			date => "Wed, 17 Jul 1996 02:23:25 -0700 (PDT)",
			subject => "IMAP4rev1 WG mtg summary and minutes",
			from => [{
				name => "Terry Gray",
				source => undef,
				mailbox => "gray",
				host => "cac.washington.edu"
			}],
			sender => [{
				name => "Terry Gray",
				source => undef,
				mailbox => "gray",
				host => "cac.washington.edu"
			}],
			reply_to => [{
				name => "Terry Gray",
				source => undef,
				mailbox => "gray",
				host => "cac.washington.edu"
			}],
			to => [{
				name => undef,
				source => undef,
				mailbox => 'imap',
				host => "cac.washington.edu",
			}],
			cc => [{
				name => undef,
				source => undef,
				mailbox => "minutes",
				host => "CNRI.Reston.VA.US",
			}, {
				name => "John Klensin",
				source => undef,
				mailbox => "KLENSIN",
				host => "MIT.EDU",
			}],
			bcc => undef,
			in_reply_to => undef,
			message_id => '<B27397-0100000@cac.washington.edu>'
		},
		body => {
			type => 'text',
			subtype => 'plain',
			parameters => {
				charset => 'US-ASCII',
			},
			id => undef,
			description => undef,
			encoding => '7bit',
			size => 3028,
			lines => 92,
		}
	}
}, {
	description => 'literal string',
	input => <<'EOF',
(TEST {5}
12345)
EOF
	result => {
		test => \'12345'
	}
}, {
	description => 'literal string for body[header]',
	input => <<'EOF',
(BODY[HEADER] {8}
12345678)
EOF
	result => {
		'body[header]' => \'12345678'
	}
}, {
	description => 'empty string for body[header]',
	input => <<'EOF',
(BODY[HEADER] "")
EOF
	result => {
		'body[header]' => ''
	}
});

plan tests => scalar @cases;
for my $test (@cases) {
	my $parser = Protocol::IMAP::FetchResponseParser->new;
	try {
		my @in = split /\n/, $test->{input};
		$parser->subscribe_to_event(
			literal_data => sub {
				my ($ev, $count, $buffref) = @_;
				warn "Expect to read $count bytes\n";
				my $txt = join("\n", @in);
				$$buffref = substr $txt, 0, $count;
				@in = split /\n/, substr $txt, $count;
			}
		);
		my $result = $parser->from_reader(sub {
			shift @in
		});
		is_deeply($result, $test->{result}, $test->{description} || 'parse fetch response');
	} catch {
		fail($_)
	}
}

done_testing;

