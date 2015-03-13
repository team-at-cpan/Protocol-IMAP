package Protocol::IMAP::Fetch;

use strict;
use warnings;
use parent qw(Mixin::Event::Dispatch);

use Future;
use Protocol::IMAP::FetchResponseParser;
use Protocol::IMAP::Envelope;
use List::Util qw(min);

sub new {
	my $class = shift;
	my $self = bless {
		parse_buffer => '',
		reading_literal => [],
		last_literal_id => 0,
		literal => [],
		@_
	}, $class;
	$self->{parser} = Protocol::IMAP::FetchResponseParser->new;
	$self->{parser}{literal} = $self->{literal};
	$self->{parser}->subscribe_to_event(
		literal_data => sub {
			my ($ev, $count, $buffer) = @_;
			return if $self->{seen_literal}{$self->parser->pos}++;
#			warn "Literal data: $count\n";
			my $id = ++$self->{last_literal_id};
			my %spec = (
				id => $id,
			);
			warn "Have pos=". $self->parser->pos . " count $count len " . length($self->{parse_buffer}) . "\n";
			eval {
				my $starter = substr $self->{parse_buffer}, $self->parser->pos, min($count, length($self->{parse_buffer}) - $self->parser->pos), '';
				$spec{literal} = $starter;
				$spec{remaining} = $count - length($starter);
				1
			} or do { $spec{literal} = ''; $spec{remaining} = $count };

			push @{$self->{reading_literal}}, \%spec;
			warn "$id - try to change buffer, currently:\n" . $self->{parse_buffer} . "\n";
			$self->{parse_buffer} =~ s/\{$count\}$/{B$id}/m or warn "could not change buffer";
		}
	);
	$self
}

sub parser { shift->{parser} }
sub parse_buffer { shift->{parse_buffer} }
sub completion { shift->{completion} ||= Future->new }

sub on_read {
	my $self = shift;
	my $buffref = shift;
	warn "reading with " . $$buffref . "\n";
	READ:
	while(1) {
		if(@{$self->{reading_literal}}) {
			my $spec = $self->{reading_literal}[0];
			warn "We are reading a literal, remaining " . $spec->{remaining} . ", our buffer is currently:\n$$buffref\n";
			my $chunk = substr $$buffref, 0, min($spec->{remaining}, length($$buffref)), '';
			$spec->{literal} .= $chunk;
			$spec->{remaining} -= length $chunk;
			return 1 if $spec->{remaining};
			warn "Completed literal read, had " . length($spec->{literal}) . " bytes\n";
			$self->{literal}[$spec->{id}] = $spec->{literal};
			shift @{$self->{reading_literal}};
			next READ;
		}
		# Result is always on one line, any \r\n chars indicate
		# end of this header or should follow a literal. Since
		# we iterate through the literals then we still want
		# to attempt to parse each one.
		if($$buffref =~ s/^([^\r\n]*)[\r\n]*//) {
			warn "[$1]\n";
			$self->{parse_buffer} .= $1;
			die "bad chars found..." if $self->parse_buffer =~ /[\r\n]/;
#			warn "Reading data, buffer is now:\n" . $self->parse_buffer;
			if($self->attempt_parse) {
				# At this point we managed to parse things successfully,
				# so we probably pulled in some data from the email that
				# we should hand back:
				$$buffref = $self->{parse_buffer} . $$buffref;
			}
			next READ if $self->attempt_parse;
			warn "parse failure, loop again";
			# Parsing failed. We may require more data due to literal values:
			last READ unless @{$self->{reading_literal}};
			next READ;
		}

		warn "no handler, buffer is currently " . $$buffref;
#		$self->{parse_buffer} .= substr $$buffref, 0, length($$buffref);
		return 0;
	}
	warn "on_read returns 1, b:\n$$buffref\npb:\n" . $self->{parse_buffer} . "\n";
	return 1;
}

sub on_done { my $self = shift; $self->completion->on_done(@_) }

#sub literal_string {
#	my $self = shift;
#	my $str = shift;
#	my $count = length($str);
#	warn "Had $count in literal string";
#	$self->{parse_buffer} =~ s/\Q{$count}\E$/""/;
#	$self->attempt_parse;
#}

sub attempt_parse {
	my $self = shift;
	my $parser = $self->parser;
	eval {
		warn "$self Will try to parse: [" . $self->parse_buffer . "]\n";
		$self->{seen_literal} = {};
		my $rslt = $parser->from_string($self->parse_buffer);
		warn "... and we're done\n";
		$self->{fetched} = $rslt;
		$self->{data}{size} = Future->new->done($rslt->{'rfc822.size'});
		$self->{parse_buffer} = '';
		$self->{reading_literal} = [];
		$self->{last_literal_id} = 0;
		splice @{$self->{literal}}, 0;
		$self->completion->done($self);
		1
	} or do {
		for($@) {
			if(/^Expected end of input/) {
				warn "Had end-of-input warning, this is good\n";
				my $txt = substr $self->{parse_buffer}, 0, $parser->pos - 1, '';
				warn "Actual parsed text:\n$txt\n";
				return 0;
			}
			warn "Failure from parser: $_\n";
			return 0
		}
	};
}

=head2 data

Returns a L<Future> which will resolve when the given
item is available. Suitable for smaller data strucures
such as the envelope. Not recommended for the full
body of a message, unless you really want to load the
entire message data into memory.

=cut

sub data {
	my $self = shift;
	my $k = shift;
	return $self->{data}{$k} if exists $self->{data}{$k};
	$self->{data}{$k} = my $f = Future->new;
	$self->completion->on_done(sub {
		$f->done(Protocol::IMAP::Envelope->new(
			%{$self->{fetched}{$k}}
		));
	});
	$f
}

=head2 stream

This is what you would normally use for a message, although
at the moment you can't, so don't.

=cut

sub stream { die 'unimplemented' }

1;

__END__

=pod

=over 4

=item * L<Protocol::IMAP::Envelope> - represents the message envelope

=item * L<Protocol::IMAP::Address> - represents an email address as found in the message envelope

=back

my $msg = $imap->fetch(message => 123);
$msg->data('envelope')->on_done(sub {
	my $envelope = shift;
	say "Date: " . $envelope->date;
	say "From: " . join ',', $envelope->from;
	say "To:   " . join ',', $envelope->to;
	say "CC:   " . join ',', $envelope->cc;
	say "BCC:  " . join ',', $envelope->bcc;
});


Implementation:

The untagged FETCH response causes instantiation of this class. We pass
the fetch line as the initial buffer, set up the parser and run the first
parse attempt.

If we already have enough data to parse the FETCH response, then we relinquish
control back to the client.

If there's a {123} string literal, then we need to stream that amount of data:
we request a new sink, primed with the data we have so far, with the byte count
({123} value) as the limit, and allow it to pass us events until completion.

In streaming mode, we'll pass those to event listeners.
Otherwise, we'll store this data internally to the appropriate key.

then switch back to line mode.

