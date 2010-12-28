package Protocol::IMAP::Client;
use strict;
use warnings;
use parent qw{Protocol::IMAP};

=head1 NAME

Protocol::IMAP::Client - client support for the Internet Mailbox Access Protocol.

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

=head2 C<on_read>

=cut

sub on_read {
	my ($self, $buffref, $closed) = @_;
	$self->debug("closed??") if $closed;

# We'll be called again, don't know where, don't know when, but the rest of our data will be waiting for us
	if($$buffref =~ s/^(.*[\n\r]+)//) {
		if($self->{multi_line}) {
			$self->on_multi_line($1);
		} else {
			$self->on_single_line($1);
		}
		return 1;
	}
	return 0;
}

=head2 C<info>

=cut

sub debug {
	my $self = shift;
	return unless $self->{debug};
	warn "@_\n";
	return $self;
}

=head2 C<state>

=cut

sub state {
	my $self = shift;
	if(@_) {
		$self->{state} = shift;
		$self->debug("State changed to " . $self->{state} . " (" . $Protocol::IMAP::StateMap{$self->{state}} . ")");
		# ConnectionEstablished => on_connection_established
		my $method = 'on' . $Protocol::IMAP::StateMap{$self->{state}};
		$method =~ s/([A-Z])/'_' . lc($1)/ge;
		if($self->{$method}) {
			$self->debug("Trying method for [$method]");
			# If the override returns false, skip the main function
			return $self->{state} unless $self->{$method}->(@_);
		}
		$self->$method(@_) if $self->can($method);
	}
	return $self->{state};
}

=head2 C<on_server_greeting>

=cut

sub on_server_greeting {
	my $self = shift;
	my $data = shift;
	$self->debug("Had valid server greeting");
	($self->{server_name}) = $data =~ /^\* OK (.*?)$/;
	$self->get_capabilities;
}

=head2 C<on_not_authenticated>

=cut

sub on_not_authenticated {
	my $self = shift;
	$self->debug("Attempt to log in");
	$self->login($self->on_user, $self->on_pass);
}

=head2 C<on_authenticated>

=cut

sub on_authenticated {
	my $self = shift;
	$self->debug("Authenticated session");
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
	if($self->state == Protocol::IMAP::ConnectionEstablished) {
		$self->check_greeting($data);
	}

	if($data =~ /^\* ([A-Z]+) (.*?)$/) {
		# untagged
		$self->handle_untagged($1, $2);
	} elsif($data =~ /^\* (\d+) (.*?)$/) {
		# untagged
		$self->handle_numeric($1, $2);
	} elsif($data =~ /^([\w]+) (OK|NO|BAD) (.*?)$/i) {
		my $id = $1;
		my $status = $2;
		my $response = $3;
		$self->debug("Check for $1 with waiting: " . join(',', keys %{$self->{waiting}}));
		my $code = $self->{waiting}->{$id};
		$code->($status, $response) if $code;
		delete $self->{waiting}->{$id};
	}
	return 1;
}

=head2 C<handle_untagged>

=cut

sub handle_untagged {
	my $self = shift;
	my ($cmd, $response) = @_;
	$self->debug("Had untagged: $cmd with data $response");
	my $method = join('_', 'check', lc $cmd);
	$self->$method($response) if $self->can($method);
	return $self;
}

=head2 C<untagged_fetch>

=cut

sub untagged_fetch {
	my $self = shift;
	my ($idx, $data) = @_;
	$self->debug("Fetch data: $data");
	my ($len) = $data =~ /{(\d+)}/;
	return $self unless defined $len;

	$self->{multiline} = {
		remaining => $len,
		buffer => '',
		on_complete => $self->_capture_weakself(sub {
			my ($self, $buffer) = @_;
			$self->{message}->{$idx} = $buffer;
		})
	};
	return $self;
}

=head2 C<handle_numeric>

=cut

sub handle_numeric {
	my $self = shift;
	my ($num, $data) = @_;
	$data =~ s/^(\w+)\s*//;
	my $cmd = $1;
	$self->debug("Now we have $cmd with $num");
	my $method = join('_', 'untagged', lc $cmd);
	$self->$method($num, $data) if $self->can($method);
	$self->{on_idle_update}->($cmd, $num) if $self->{on_idle_update} && $self->{in_idle};
	return $self;
}

=head2 C<check_capability>

=cut

sub check_capability {
	my $self = shift;
	my $data = shift;
	foreach my $cap (split ' ', $data) {
		$self->debug("Have cap: $cap");
		if($cap =~ /^auth=(.*)/i) {
			push @{ $self->{authtype} }, $1;
		} else {
			$self->{capability}->{$cap} = 1;
		}
	}
	die "Not IMAP4rev1-capable" unless $self->{capability}->{'IMAP4rev1'};
}

=head2 C<on_message>

=cut

sub on_message {
	my $self = shift;
	my $msg = shift;

}

=head2 C<check_greeting>

=cut

sub check_greeting {
	my $self = shift;
	my $data = shift;
	if($data =~ /^\* OK/) {
		$self->state(Protocol::IMAP::ServerGreeting, $data);
	} else {
		$self->state(Protocol::IMAP::Logout);
	}
}

=head2 C<get_capabilities>

=cut

sub get_capabilities {
	my $self = shift;
	$self->send_command(
		command		=> 'CAPABILITY',
		on_ok		=> $self->_capture_weakself(sub {
			my $self = shift;
			my $data = shift;
			$self->debug("Successfully retrieved caps: $data");
			$self->state(Protocol::IMAP::NotAuthenticated);
		}),
		on_bad		=> $self->_capture_weakself(sub {
			my $self = shift;
			my $data = shift;
			$self->debug("Caps retrieval failed: $data");
		})
	);
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

=head2 C<push_waitlist>

=cut

sub push_waitlist {
	my $self = shift;
	my $id = shift;
	my $sub = shift;
	$self->{waiting}->{$id} = $sub;
	return $self;
}

=head2 C<send_command>

=cut

sub send_command {
	my $self = shift;
	my %args = @_;
	my $id = exists $args{id} ? $args{id} : $self->next_id;
	my $cmd = $args{command};
	my $data = defined $id ? "$id " : '';
	$data .= $cmd;
	$data .= ' ' . $args{param} if $args{param};
	$self->push_waitlist($id, sub {
		my ($status, $data) = @_;
		my $method = join('_', 'on', lc $status);
		$args{$method}->($data) if exists $args{$method};
		$args{on_response}->("$status $data") if exists $args{on_response};
	}) if defined $id;
	$self->debug("Sending [$data] to server");
	if($self->{in_idle} && defined $id) {
# If we're currently in IDLE mode, we have to finish the current command first by issuing the DONE command.
		$self->{idle_queue} = $data;
		$self->done;
	} else {
		$self->write("$data\r\n");
		$self->{in_idle} = 1 if $args{command} eq 'IDLE';
	}
	return $id;
}

=head2 C<login>

=cut

sub login {
	my ($self, $user, $pass) = @_;
	$self->send_command(
		command		=> 'LOGIN',
		param		=> qq{$user "$pass"},
		on_ok		=> $self->_capture_weakself(sub {
			my $self = shift;
			my $data = shift;
			$self->debug("Successfully logged in: $data");
			$self->state(Protocol::IMAP::Authenticated);
		}),
		on_bad		=> $self->_capture_weakself(sub {
			my $self = shift;
			my $data = shift;
			$self->debug("Login failed: $data");
		})
	);
	return $self;
}

=head2 C<check_status>

=cut

sub check_status {
	my $self = shift;
	my $data = shift;
	my %status;
	my ($mbox) = $data =~ /([^ ]+)/;
	$mbox =~ s/^(['"])(.*)\1$/$2/;
	foreach (qw(MESSAGES UNSEEN RECENT UIDNEXT)) {
		$status{lc($_)} = $1 if $data =~ /$_ (\d+)/;
	}
	$self->{status}->{$mbox} = \%status;
	return $self;
}

=head2 C<noop>

=cut

sub noop {
	my $self = shift;
	my %args = @_;

	$self->send_command(
		command		=> 'NOOP',
		on_ok		=> sub {
			my $data = shift;
			$self->debug("Status completed");
			$args{on_ok}->() if $args{on_ok};
		},
		on_bad		=> sub {
			my $data = shift;
			$self->debug("Login failed: $data");
		}
	);
	return $self;
}

=head2 C<status>

=cut

sub status {
	my $self = shift;
	my %args = @_;

	my $mbox = $args{mailbox} || 'INBOX';
	$self->send_command(
		command		=> 'STATUS',
		param		=> "$mbox (unseen recent messages uidnext)",
		on_ok		=> sub {
			my $data = shift;
			$self->debug("Status completed");
			$args{on_ok}->($self->{status}->{$mbox}) if $args{on_ok};
		},
		on_bad		=> sub {
			my $data = shift;
			$self->debug("Login failed: $data");
		}
	);
	return $self;
}

=head2 C<select>

=cut

sub select : method {
	my $self = shift;
	my %args = @_;

	my $mbox = $args{mailbox} || 'INBOX';
	$self->send_command(
		command		=> 'SELECT',
		param		=> $mbox,
		on_ok		=> sub {
			my $data = shift;
			$self->debug("Have selected");
			$args{on_ok}->($self->{status}->{$mbox}) if $args{on_ok};
		},
		on_bad		=> sub {
			my $data = shift;
			$self->debug("Login failed: $data");
		}
	);
	return $self;
}

=head2 C<fetch>

=cut

sub fetch : method {
	my $self = shift;
	my %args = @_;

	my $msg = $args{message} // 1;
	my $type = $args{type} // 'ALL';
	$self->send_command(
		command		=> 'FETCH',
		param		=> "$msg $type",
		on_ok		=> sub {
			my $data = shift;
			$self->debug("Have fetched");
			$args{on_ok}->($self->{message}->{$msg}) if $args{on_ok};
		},
		on_bad		=> sub {
			my $data = shift;
			$self->debug("Login failed: $data");
		}
	);
	return $self;
}

=head2 C<delete>

=cut

sub delete : method {
	my $self = shift;
	my %args = @_;

	my $msg = $args{message} // 1;
	$self->send_command(
		command		=> 'STORE',
		param		=> $msg . ' +FLAGS (\Deleted)',
		on_ok		=> sub {
			my $data = shift;
			$self->debug("Have deleted");
			$args{on_ok}->() if $args{on_ok};
		},
		on_bad		=> sub {
			my $data = shift;
			$self->debug("Login failed: $data");
		}
	);
	return $self;
}

=head2 C<expunge>

=cut

sub expunge : method {
	my $self = shift;
	my %args = @_;

	$self->send_command(
		command		=> 'EXPUNGE',
		on_ok		=> sub {
			my $data = shift;
			$self->debug("Have expunged");
			$args{on_ok}->() if $args{on_ok};
		},
		on_bad		=> sub {
			my $data = shift;
			$self->debug("Login failed: $data");
		}
	);
	return $self;
}

=head2 C<done>

=cut

sub done {
	my $self = shift;
	my %args = @_;

	$self->send_command(
		command		=> 'DONE',
		id		=> undef,
		on_ok		=> sub {
			my $data = shift;
			$self->debug("Done completed");
			$args{on_ok}->() if $args{on_ok};
		},
		on_bad		=> sub {
			my $data = shift;
			$self->debug("Login failed: $data");
		}
	);
	return $self;
}

=head2 C<idle>

=cut

sub idle {
	my $self = shift;
	my %args = @_;

	$self->{start_idle_timer}->(%args) if $self->{start_idle_timer};
	$self->send_command(
		command		=> 'IDLE',
		on_ok		=> $self->_capture_weakself( sub {
			my $data = shift;
			$self->debug("Left IDLE mode");
			$self->{idle_timer}->stop if $self->{idle_timer};
			$self->{in_idle} = 0;
			my $queued = $self->{idle_queue};
			$self->write("$queued\r\n") if $queued;
			$args{on_ok}->() if $args{on_ok};
		}),
		on_bad		=> sub {
			my $data = shift;
			$self->debug("Idle failed: $data");
			$self->{in_idle} = 0;
		}
	);
	return $self;
}

sub is_multi_line { shift->{multiline} ? 1 : 0 }

=head2 C<queue_write>

Queue up a write for this stream. Adds to the existing send buffer array if there is one.

When a write is queued, this will send a notification to the on_queued_write callback if one
was defined.

=cut

sub write {
	my $self = shift;
	my $v = shift;
	$self->debug("Queued a write for [$v]");
	push @{$self->{write_buffer}}, $v;
	$self->{on_queued_write}->() if $self->{on_queued_write};
	return $self;
}

=head2 C<write_buffer>

Returns the contents of the current write buffer without changing it.

=cut

sub write_buffer { shift->{write_buffer} }

=head2 C<extract_write>

Retrieves next pending message from the write buffer and removes it from the list.

=cut

sub extract_write {
	my $self = shift;
	return undef unless @{$self->{write_buffer}};
	my $v = shift @{$self->{write_buffer}};
	$self->debug("Extract write [$v]");
	return $v;
}

=head2 C<ready_to_send>

Returns true if there's data ready to be written.

=cut

sub ready_to_send {
	my $self = shift;
	$self->debug('Check whether ready to send, current length '. @{$self->{write_buffer}});
	return @{$self->{write_buffer}};
}

=head2 C<configure>

Set up any callbacks that were available.

=cut

sub configure {
	my $self = shift;
	my %args = @_;
	foreach (Protocol::IMAP::STATE_HANDLERS, qw{on_idle_update}) {
		warn("Apply handler for $_");
		$self->{$_} = delete $args{$_} if exists $args{$_};
	}
	return %args;
}

=head2 C<_capture_weakself>

Helper method to avoid capturing $self in closures, using the same approach and method name
as in L<IO::Async>.

=cut

sub _capture_weakself {
	my ($self, $code) = @_;

	Scalar::Util::weaken($self);

	return sub {
		$self->$code(@_)
	};
}

1;
