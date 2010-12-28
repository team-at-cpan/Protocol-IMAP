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

=head2 C<read_command>

Read a command from a single line input from the client.

If this is a supported command, calls the relevant request_XXX method with the following data as a hash:

=over 4

=item * tag - IMAP tag information for this command, used for the final response from the server

=item * command - actual command requested

=item * param - any additional parameters passed after the command

=back

=cut

sub read_command {
	my $self = shift;
	my $data = shift;
	my ($id, $cmd, $param) = split / /, $data, 3;
	my $method = "request_" . lc $cmd;
	if($self->can($method)) {
		return $self->$method(
			id	=> $id,
			command => $cmd, 
			param	=> $param
		);
	} else {
		return $self->send_tagged($id, 'BAD', 'wtf dude');
	}
}

sub request_capability {
	my $self = shift;
	my %args = @_;
	if(length $args{param}) {
		$self->send_tagged($args{id}, 'BAD', 'Extra parameters detected');
	} else {
		$self->send_untagged('CAPABILITY', @{$self->{capabilities}});
		$self->send_tagged($args{id}, 'OK', 'Capability completed');
	}
}

sub request_starttls {
	my $self = shift;
	my %args = @_;
	if(length $args{param}) {
		$self->send_tagged($args{id}, 'BAD', 'Extra parameters detected');
	} else {
		$self->send_tagged($args{id}, 'OK', 'Logged in.');
	}
}

sub request_authenticate {
	my $self = shift;
	my %args = @_;
	if(0) {
		my ($user, $pass);
		my $sasl = Authen::SASL->new(
			mechanism => $args{param},
			callback => {
	# TODO Convert these to plain values or sapped entries
				pass => sub { $pass },
				user => sub { $user },
				authname => sub { warn @_; }
			}
		);
		my $s = $sasl->server_new(
			'imap',
			$self->server_name,
			0,
		);
	}
	$self->send_tagged($args{id}, 'NO', 'Not yet supported.');
}

sub is_authenticated {
	my $self = shift;
	return $self->state > 1;
}

sub request_login {
	my $self = shift;
	my %args = @_;
	my ($user, $pass) = split ' ', $args{param}, 2;
	if($self->validate_user(user => $user, pass => $pass)) {
		$self->state(Protocol::IMAP::Authenticated);
		$self->send_tagged($args{id}, 'OK', 'Logged in.');
	} else {
		$self->send_tagged($args{id}, 'NO', 'Invalid user or password.');
	}
}

sub request_logout {
	my $self = shift;
	my %args = @_;
	if(length $args{param}) {
		$self->send_tagged($args{id}, 'BAD', 'Extra parameters detected');
	} else {
		$self->send_untagged('BYE', 'IMAP4rev1 server logging out');
		$self->state(Protocol::IMAP::NotAuthenticated);
		$self->send_tagged($args{id}, 'OK', 'Logout completed.');
	}
}

sub request_noop {
	my $self = shift;
	my %args = @_;
	if(length $args{param}) {
		$self->send_tagged($args{id}, 'BAD', 'Extra parameters detected');
	} else {
		$self->send_tagged($args{id}, 'OK', 'NOOP completed');
	}
}

sub request_select {
	my $self = shift;
	my %args = @_;
	unless($self->is_authenticated) {
		return $self->send_tagged($args{id}, 'NO', 'Not authorized.');
	}
	if(my $mailbox = $self->select_mailbox(mailbox => $args{param}, readonly => 1)) {
		$self->send_untagged($mailbox->{'exists'} // 0, 'EXISTS');
		$self->send_untagged($mailbox->{'recent'} // 0, 'RECENT');
		$self->send_untagged('OK', '[UNSEEN ' . ($mailbox->{'first_unseen'} // 0) . ']', 'First unseen message ID');
		$self->send_untagged('OK', '[UIDVALIDITY ' . ($mailbox->{'uid_valid'} // 0) . ']', 'Valid UIDs');
		$self->send_untagged('OK', '[UIDNEXT ' . ($mailbox->{'uid_next'} // 0) . ']', 'Predicted next UID');
		$self->send_untagged('FLAGS', '(\Answered \Flagged \Deleted \Seen \Draft)'); 
		$self->send_tagged($args{id}, 'OK', 'Mailbox selected.');
	} else {
		$self->send_tagged($args{id}, 'NO', 'Mailbox not found.');
	}
}

sub request_examine {
	my $self = shift;
	my %args = @_;
	unless($self->is_authenticated) {
		return $self->send_tagged($args{id}, 'NO', 'Not authorized.');
	}
	if(my $mailbox = $self->select_mailbox(mailbox => $args{param}, readonly => 1)) {
		$self->send_untagged($mailbox->{'exists'} // 0, 'EXISTS');
		$self->send_untagged($mailbox->{'recent'} // 0, 'RECENT');
		$self->send_untagged('OK', '[UNSEEN ' . ($mailbox->{'first_unseen'} // 0) . ']', 'First unseen message ID');
		$self->send_untagged('OK', '[UIDVALIDITY ' . ($mailbox->{'uid_valid'} // 0) . ']', 'Valid UIDs');
		$self->send_untagged('OK', '[UIDNEXT ' . ($mailbox->{'uid_next'} // 0) . ']', 'Predicted next UID');
		$self->send_untagged('FLAGS', '(\Answered \Flagged \Deleted \Seen \Draft)'); 
		$self->send_tagged($args{id}, 'OK', 'Mailbox selected.');
	} else {
		$self->send_tagged($args{id}, 'NO', 'Mailbox not found.');
	}
}

sub request_create {
	my $self = shift;
	my %args = @_;
	unless($self->is_authenticated) {
		return $self->send_tagged($args{id}, 'NO', 'Not authorized.');
	}
	if(my $mailbox = $self->create_mailbox(mailbox => $args{param})) {
		$self->send_tagged($args{id}, 'OK', 'Mailbox created.');
	} else {
		$self->send_tagged($args{id}, 'NO', 'Unable to create mailbox.');
	}
}

sub request_delete {
	my $self = shift;
	my %args = @_;
	unless($self->is_authenticated) {
		return $self->send_tagged($args{id}, 'NO', 'Not authorized.');
	}
	if(my $mailbox = $self->delete_mailbox(mailbox => $args{param})) {
		$self->send_tagged($args{id}, 'OK', 'Mailbox deleted.');
	} else {
		$self->send_tagged($args{id}, 'NO', 'Unable to delete mailbox.');
	}
}

sub request_rename {
	my $self = shift;
	my %args = @_;
	unless($self->is_authenticated) {
		return $self->send_tagged($args{id}, 'NO', 'Not authorized.');
	}
	my ($src, $dst) = split ' ', $args{param}, 2;
	if(my $mailbox = $self->rename_mailbox(mailbox => $src, target => $dst)) {
		$self->send_tagged($args{id}, 'OK', 'Mailbox renamed.');
	} else {
		$self->send_tagged($args{id}, 'NO', 'Unable to rename mailbox.');
	}
}

sub request_subscribe {
	my $self = shift;
	my %args = @_;
	unless($self->is_authenticated) {
		return $self->send_tagged($args{id}, 'NO', 'Not authorized.');
	}
	if(my $mailbox = $self->subscribe_mailbox(mailbox => $args{param})) {
		$self->send_tagged($args{id}, 'OK', 'Subscribed to mailbox.');
	} else {
		$self->send_tagged($args{id}, 'NO', 'Unable to subscribe to mailbox.');
	}
}

sub request_unsubscribe {
	my $self = shift;
	my %args = @_;
	unless($self->is_authenticated) {
		return $self->send_tagged($args{id}, 'NO', 'Not authorized.');
	}
	if(my $mailbox = $self->unsubscribe_mailbox(mailbox => $args{param})) {
		$self->send_tagged($args{id}, 'OK', 'Unsubscribed from mailbox.');
	} else {
		$self->send_tagged($args{id}, 'NO', 'Unable to unsubscribe from mailbox.');
	}
}

sub request_list {
	my $self = shift;
	my %args = @_;
	unless($self->is_authenticated) {
		return $self->send_tagged($args{id}, 'NO', 'Not authorized.');
	}
	if(my $status = $self->list_mailbox(mailbox => $args{param})) {
		$self->send_tagged($args{id}, 'OK', 'List completed.');
	} else {
		$self->send_tagged($args{id}, 'NO', 'Failed to list mailboxes.');
	}
}

sub request_lsub {
	my $self = shift;
	my %args = @_;
	unless($self->is_authenticated) {
		return $self->send_tagged($args{id}, 'NO', 'Not authorized.');
	}
	if(my $status = $self->list_subscription(mailbox => $args{param})) {
		$self->send_tagged($args{id}, 'OK', 'List completed.');
	} else {
		$self->send_tagged($args{id}, 'NO', 'Failed to list subscriptions.');
	}
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
	$self->read_command($data);
	return 1;

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
	$self->{capabilities} = [qw{IMAP4rev1 IDLE AUTH=LOGIN AUTH=PLAIN}];
	return %args;
}

=head2 C<add_capability>

Add a new capability to the reported list.

=cut

sub add_capability {
	my $self = shift;
	push @{$self->{capabilities}}, @_;
}

=head2 C<validate_user>

Validate the given user and password information, returning true if they have logged in successfully
and false if they are invalid.

=cut

sub validate_user {
	my $self = shift;
	my %args = @_;
}

=head2 C<select_mailbox>

Selects the given mailbox.

=cut

sub select_mailbox {
	my $self = shift;
	my %args = @_;
}

=head2 C<create_mailbox>

Creates the given mailbox on the server.

=cut

sub create_mailbox {
	my $self = shift;
	my %args = @_;
}

=head2 C<delete_mailbox>

Deletes the given mailbox.

=cut

sub delete_mailbox {
	my $self = shift;
	my %args = @_;
}

=head2 C<rename_mailbox>

Renames the given mailbox.

=cut

sub rename_mailbox {
	my $self = shift;
	my %args = @_;
}

=head2 C<subscribe_mailbox>

Adds the given mailbox to the active subscription list.

=cut

sub subscribe_mailbox {
	my $self = shift;
	my %args = @_;
}

=head2 C<unsubscribe_mailbox>

Removes the given mailbox from the current user's subscription list.

=cut

sub unsubscribe_mailbox {
	my $self = shift;
	my %args = @_;
}

=head2 C<list_mailbox>

List mailbox information given a search spec.

=cut

sub list_mailbox {
	my $self = shift;
	my %args = @_;
}

=head2 C<list_subscription>

List subscriptions given a search spec.

=cut

sub list_subscription {
	my $self = shift;
	my %args = @_;
}

1;
