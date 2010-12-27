package Protocol::IMAP;
# ABSTRACT: Asynchronous IMAP client
use strict;
use warnings;

use Encode::IMAPUTF7;
use Socket;
use Scalar::Util qw{weaken};
use Authen::SASL;

our $VERSION = '0.001';

=pod

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

=cut

# Build up an enumerated list of states. These are defined in the RFC and are used to indicate what we expect to send / receive at client and server ends.
our %StateMap;
BEGIN {
	my $stateId = 0;
	foreach (qw{ConnectionClosed ConnectionEstablished ServerGreeting NotAuthenticated Authenticated Selected Logout}) {
		{ no strict 'refs'; *{__PACKAGE__ . '::' . $_} = sub () { $stateId; }; }
		$StateMap{$stateId} = $_;
		++$stateId;
	}
	my @handlers = sort values %StateMap;
	@handlers = map { $_ = "on$_"; s/([A-Z])/'_' . lc($1)/ge; $_ } @handlers;
	{ no strict 'refs'; *{__PACKAGE__ . "::STATE_HANDLERS"} = sub () { @handlers; }; }
}

=head2 C<new>

=cut

sub new {
	my $class = shift;
	my %args = @_;

	my $loop = delete $args{loop};
	my $self = $class->SUPER::new( %args );
	# $self->{debug} = 1;
	$loop->add($self) if $loop;
	return $self;
}

=head2 C<on_read>

=cut

sub on_read {
	my ($self, $buffref, $closed) = @_;
	$self->info("closed??") if $closed;

# We'll be called again, don't know where, don't know when, but the rest of our data will be waiting for us
	if($$buffref =~ s/^(.*[\n\r]+)//) {
		if($self->{multiline}) {
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

sub info {
	my $self = shift;
	return unless $self->{debug};
	warn "@_\n";
	return $self;
}

=head2 C<configure>

=cut

sub configure {
	my $self = shift;
	my %args = @_;

	die "No host provided" unless $args{host};
	foreach (qw{host service user pass}) {
		$self->{$_} = delete $args{$_} if exists $args{$_};
	}
	foreach (STATE_HANDLERS, qw{on_idle_update}) {
		$self->{$_} = delete $args{$_} if exists $args{$_};
	}
	$self->SUPER::configure(%args);
	return $self;
}

=head2 C<state>

=cut

sub state {
	my $self = shift;
	if(@_) {
		$self->{state} = shift;
		$self->info("State changed to " . $self->{state});
		# ConnectionEstablished => on_connection_established
		my $method = 'on' . $StateMap{$self->{state}};
		$method =~ s/([A-Z])/'_' . lc($1)/ge;
		if($self->{$method}) {
			# If the override returns false, skip the main function
			return $self->{state} unless $self->{$method}->(@_);
		}
		$self->$method(@_) if $self->can($method);
	}
	return $self->{state};
}

=head2 C<on_connection_established>

=cut

sub on_connection_established {
	my $self = shift;
	my $sock = shift;
	my $transport = IO::Async::Stream->new(handle => $sock)
		or die "No transport?";
	$self->{transport} = $transport;
	$self->setup_transport($transport);
	my $loop = $self->get_loop or die "No IO::Async::Loop available";
	$loop->add($transport);
	$self->info("Have transport " . $self->transport);
}

=head2 C<on_server_greeting>

=cut

sub on_server_greeting {
	my $self = shift;
	my $data = shift;
	$self->info("Had valid server greeting");
	($self->{server_name}) = $data =~ /^\* OK (.*?)$/;
	$self->get_capabilities;
}

=head2 C<on_not_authenticated>

=cut

sub on_not_authenticated {
	my $self = shift;
	$self->info("Attempt to log in");
	$self->login($self->{user}, $self->{pass});
}

=head2 C<on_authenticated>

=cut

sub on_authenticated {
	my $self = shift;
	$self->info("Authenticated session");
}

=head2 C<_add_to_loop>

=cut

sub _add_to_loop {
	my $self = shift;
	$self->SUPER::_add_to_loop(@_);
	my $loop = $self->get_loop or die "No IO::Async::Loop available";
	my $host = $self->{host};
	$self->state(ConnectionClosed);
	weaken(my $weakSelf = $self);
	$loop->connect(
		host => $self->{host},
		service => $self->{service} || 'imap2',
		socktype => SOCK_STREAM,
		on_resolve_error => sub {
			die "Resolution failed for $host";
		},
		on_connect_error => sub {
			die "Could not connect to $host";
		},
		on_connected => sub {
			my $sock = shift;
			$weakSelf->state(ConnectionEstablished, $sock);
		}
	);
	return $self;
}

=head2 C<on_multi_line>

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

=cut

sub on_single_line {
	my ($self, $data) = @_;

	$data =~ s/[\r\n]+//g;
	$self->info("Had [$data]");
	if($self->state == ConnectionEstablished) {
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
		$self->info("Check for $1 with waiting: " . join(',', keys %{$self->{waiting}}));
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
	$self->info("Had untagged: $cmd with data $response");
	my $method = join('_', 'check', lc $cmd);
	$self->$method($response) if $self->can($method);
	return $self;
}

=head2 C<untagged_fetch>

=cut

sub untagged_fetch {
	my $self = shift;
	my ($idx, $data) = @_;
	$self->info("Fetch data: $data");
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
	$self->info("Now we have $cmd with $num");
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
		$self->info("Have cap: $cap");
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
		$self->state(ServerGreeting, $data);
	} else {
		$self->state(Logout);
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
			$self->info("Successfully retrieved caps: $data");
			$self->state(NotAuthenticated);
		}),
		on_bad		=> $self->_capture_weakself(sub {
			my $self = shift;
			my $data = shift;
			$self->info("Caps retrieval failed: $data");
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
	$self->info("Sending [$data] to server");
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
			my $data = shift;
			$self->info("Successfully logged in: $data");
			$self->state(Authenticated);
		}),
		on_bad		=> $self->_capture_weakself(sub {
			my $data = shift;
			$self->info("Login failed: $data");
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
			$self->info("Status completed");
			$args{on_ok}->() if $args{on_ok};
		},
		on_bad		=> sub {
			my $data = shift;
			$self->info("Login failed: $data");
		}
	);
	return $self;
}

=head2 C<status>

=cut

sub status {
	my $self = shift;
	my %args = @_;

	my $mbox = $args{mbox} || 'INBOX';
	$self->send_command(
		command		=> 'STATUS',
		param		=> "$mbox (unseen recent messages uidnext)",
		on_ok		=> sub {
			my $data = shift;
			$self->info("Status completed");
			$args{on_ok}->($self->{status}->{$mbox}) if $args{on_ok};
		},
		on_bad		=> sub {
			my $data = shift;
			$self->info("Login failed: $data");
		}
	);
	return $self;
}

=head2 C<select>

=cut

sub select : method {
	my $self = shift;
	my %args = @_;

	my $mbox = $args{mbox} || 'INBOX';
	$self->send_command(
		command		=> 'SELECT',
		param		=> $mbox,
		on_ok		=> sub {
			my $data = shift;
			$self->info("Have selected");
			$args{on_ok}->($self->{status}->{$mbox}) if $args{on_ok};
		},
		on_bad		=> sub {
			my $data = shift;
			$self->info("Login failed: $data");
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
			$self->info("Have fetched");
			$args{on_ok}->($self->{message}->{$msg}) if $args{on_ok};
		},
		on_bad		=> sub {
			my $data = shift;
			$self->info("Login failed: $data");
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
			$self->info("Have deleted");
			$args{on_ok}->() if $args{on_ok};
		},
		on_bad		=> sub {
			my $data = shift;
			$self->info("Login failed: $data");
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
			$self->info("Have expunged");
			$args{on_ok}->() if $args{on_ok};
		},
		on_bad		=> sub {
			my $data = shift;
			$self->info("Login failed: $data");
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
			$self->info("Done completed");
			$args{on_ok}->() if $args{on_ok};
		},
		on_bad		=> sub {
			my $data = shift;
			$self->info("Login failed: $data");
		}
	);
	return $self;
}

=head2 C<add_idle_timer>

=cut

sub add_idle_timer {
	my $self = shift;
	my %args = @_;

	$self->{idle_timer}->stop if $self->{idle_timer};
	$self->{idle_timer} = IO::Async::Timer::Countdown->new(
		delay => $args{idle_timeout} // 25 * 60,
		on_expire => $self->_capture_weakself( sub {
			my $self = shift;
			$self->done(
				on_ok => sub {
					$self->noop(
						on_ok => sub {
							$self->idle(%args);
						}
					);
				}
			);
		})
	);
	my $loop = $self->get_loop or die "Could not get loop";
	$loop->add($self->{idle_timer});
	$self->{idle_timer}->start;
	return $self;
}

=head2 C<idle>

=cut

sub idle {
	my $self = shift;
	my %args = @_;

	$self->add_idle_timer(%args);
	$self->send_command(
		command		=> 'IDLE',
		on_ok		=> $self->_capture_weakself( sub {
			my $data = shift;
			$self->info("Left IDLE mode");
			$self->{idle_timer}->stop if $self->{idle_timer};
			$self->{in_idle} = 0;
			my $queued = $self->{idle_queue};
			$self->write("$queued\r\n") if $queued;
			$args{on_ok}->() if $args{on_ok};
		}),
		on_bad		=> sub {
			my $data = shift;
			$self->info("Idle failed: $data");
			$self->{in_idle} = 0;
		}
	);
	return $self;
}

1;
