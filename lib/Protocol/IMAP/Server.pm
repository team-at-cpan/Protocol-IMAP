package Protocol::IMAP::Server;
use strict;
use warnings;
use parent qw{Protocol::IMAP};

=head1 NAME

Protocol::IMAP::Server - server support for the Internet Mailbox Access Protocol.

=head1 SYNOPSIS


=head1 DESCRIPTION

Server response:

=over 4

=item * OK - Command was successful

=item * NO - The server's having none of it

=item * BAD - You sent something invalid

=back

The IMAP connection will be in one of the following states:

=over 4

=item * ConnectionEstablished - we have a valid socket but no data has been exchanged yet, waiting for ServerGreeting

=item * ServerGreeting - server has sent an initial greeting, for some servers this may take a few seconds

=item * NotAuthenticated - server is waiting for client response, and the client has not yet been authenticated

=item * Authenticated - server is waiting on client but we have valid authentication credentials, for PREAUTH state this may happen immediately after ServerGreeting

=item * Selected - mailbox has been selected and we have valid context for commands

=item * Logout - logout request has been issued, waiting for server response

=item * ConnectionClosed - connection has been closed on both sides

=back

State changes are provided by the L<state> method.

=head1 IMPLEMENTING SUBCLASSES

The L<Protocol::IMAP> class only provides the framework for handling IMAP data. Typically you would need to subclass this to get a usable IMAP implementation.

The following methods are required:

=over 4

=item * write - called at various points to send data back across to the other side of the IMAP connection

=item * on_user - called when the user name is required for the login stage

=item * on_pass - called when the password is required for the login stage

=item * start_idle_timer - switching into idle mode, hint to start the timer so that we can refresh the session as required

=item * stop_idle_timer - switch out of idle mode due to other tasks that need to be performed

=back

Optionally, you may consider providing these:

=over 4

=item * on_starttls - the STARTTLS stanza has been received and we need to upgrade to a TLS connection. This only applies to STARTTLS connections, which start in plaintext - a regular SSL connection will be SSL encrypted from the initial connection onwards.

=back

To pass data back into the L<Protocol::IMAP> layer, you will need the following methods:

=over 4

=item * is_multi_line - send a single line of data for handling

=item * on_single_line - send a single line of data for handling

=item * on_multi_line - send a multi-line section for handling

=back

=cut

=head2 C<new>

=cut

sub new {
	my $class = shift;
	my $self = bless { @_ }, $class;
	return $self;
}

sub on_connect {
	my $self = shift;
	$self->send_untagged("OK", "Net::Async::IMAP::Server ready.");
	$self->state(Protocol::IMAP::ConnectionEstablished);
}

sub send_untagged {
	my ($self, $cmd, @data) = @_;
	$self->debug("Send untagged command $cmd");
	$self->write("* $cmd" . (@data ? join(' ', '', @data) : '') . "\n");
}

sub send_tagged {
	my ($self, $id, $status, @data) = @_;
	$self->debug("Send tagged command $status for $id");
	$self->write("$id $status" . (@data ? join(' ', '', @data) : '') . "\n");
}

sub read_command {
	my $self = shift;
	my $data = shift;
	my ($id, $cmd, $param) = split / /, $data, 3;
	my $method = "request_" . lc $cmd;
	if($self->can($method)) {
		return $self->$method($cmd, $param);
	} else {
		return $self->send_tagged($id, 'BAD', 'wtf dude');
	}
}

sub request_capability {
	my $self = shift;
	my $id = shift;
	$self->send_untagged('CAPABILITY', @{$self->{capabilities}});
	$self->send_tagged($id, 'OK', 'Capability completed');
}

sub request_login {
	my $self = shift;
	my $id = shift;
	$self->send_tagged($id, 'OK', 'Logged in.');
	$self->state(Protocol::IMAP::Authenticated);
}

=head2 C<on_multi_line>

Called when we have multi-line data (fixed size in characters).

=cut

sub on_multi_line {
	my ($self, $data) = @_;

	if($self->{multiline}->{remaining}) {
		$self->{multiline}->{buffer} .= $data;
		$self->{multiline}->{remaining} -= length($data);
	} else {
		$self->{multiline}->{on_complete}->($self->{multiline}->{buffer});
		delete $self->{multiline};
	}
	return $self;
}

=head2 C<on_single_line>

Called when there's more data to process for a single-line (standard mode) response.

=cut

sub on_single_line {
	my ($self, $data) = @_;

	$data =~ s/[\r\n]+//g;
	$self->debug("Had [$data]");

	if($data =~ /^\* ([A-Z]+) (.*?)$/) {
		# untagged
		$self->handle_untagged($1, $2);
	} elsif($data =~ /^\* (\d+) (.*?)$/) {
		# untagged
		$self->handle_numeric($1, $2);
	} else {
		$self->debug("wtf: [$data]");
	}
	return 1;
}

=head2 C<next_id>

=cut

sub next_id {
	my $self = shift;
	unless($self->{id}) {
		$self->{id} = 'A0001';
	}
	my $id = $self->{id};
	++$self->{id};
	return $id;
}

sub is_multi_line { shift->{multiline} ? 1 : 0 }

=head2 C<configure>

Set up any callbacks that were available.

=cut

sub configure {
	my $self = shift;
	my %args = @_;
	foreach (Protocol::IMAP::STATE_HANDLERS, qw{on_idle_update}) {
		$self->{$_} = delete $args{$_} if exists $args{$_};
	}
	return %args;
}

1;
