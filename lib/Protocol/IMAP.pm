package Protocol::IMAP;
# ABSTRACT: Support for RFC3501 Internet Message Access Protocol (IMAP4)
use strict;
use warnings;

use Encode::IMAPUTF7;
use Scalar::Util qw{weaken};
use Authen::SASL;

use Time::HiRes qw{time};
use POSIX qw{strftime};

our $VERSION = '0.003';

=head1 NAME

Protocol::IMAP - support for the Internet Message Access Protocol as defined in RFC3501.

=head1 SYNOPSIS

 use Protocol::IMAP::Server;
 use Protocol::IMAP::Client;

=head1 DESCRIPTION

Base class for L<Protocol::IMAP::Server> and L<Protocol::IMAP::Client> implementations.

=head1 METHODS

=cut

# Build up an enumerated list of states. These are defined in the RFC and are used to indicate what we expect to send / receive at client and server ends.
our %VALID_STATES;
our %STATE_BY_ID;
our %STATE_BY_NAME;
BEGIN {
	our @STATES = qw{
		ConnectionClosed ConnectionEstablished
		ServerGreeting
		NotAuthenticated Authenticated
		Selected
		Logout
	};
	%VALID_STATES = map { $_ => 1 } @STATES;
	my $state_id = 0;
	foreach (@STATES) {
		my $id = $state_id;
		{ no strict 'refs'; *{__PACKAGE__ . '::' . $_} = sub () { $id } }
		$STATE_BY_ID{$state_id} = $_;
		++$state_id;
	}
	%STATE_BY_NAME = reverse %STATE_BY_ID;

	# Convert from ConnectionClosed to on_connection_closed, etc.
	my @handlers = sort values %STATE_BY_ID;
	@handlers = map {;
		my $v = "on$_";
		$v =~ s/([A-Z])/'_' . lc($1)/ge;
		$v
	} @handlers;
	{ no strict 'refs'; *{__PACKAGE__ . "::STATE_HANDLERS"} = sub () { @handlers } }
}

sub new {
	my $class = shift;
	bless { @_ }, $class
}

=head2 C<debug>

Debug log message. Only displayed if the debug flag was passed to L<configure>.

=cut

sub debug {
	my $self = shift;
	return $self unless $self->{debug};

	my $now = Time::HiRes::time;
	warn strftime("%Y-%m-%d %H:%M:%S", gmtime($now)) . sprintf(".%03d", int($now * 1000.0) % 1000.0) . " @_\n";
	return $self;
}

=head2 C<state>

=cut

sub state {
	my $self = shift;
	if(@_) {
		my $name = shift;
		$self->{state_id} = $STATE_BY_NAME{$name} or die "Invalid state [$name]";
		$self->debug("State changed to " . $self->{state_id} . " (" . $Protocol::IMAP::STATE_BY_ID{$self->{state_id}} . ")");
		# ConnectionEstablished => on_connection_established
		my $method = 'on' . $Protocol::IMAP::STATE_BY_ID{$self->{state_id}};
		$method =~ s/([A-Z])/'_' . lc($1)/ge;
		if($self->{$method}) {
			$self->debug("Trying method for [$method]");
			# If the override returns false, skip the main function
			return $self->{state_id} unless $self->{$method}->(@_);
		}
		$self->$method(@_) if $self->can($method);
	}
	return $STATE_BY_ID{$self->{state_id}};
}

=head2 state_id

Returns the state matching the given ID.

=cut

sub state_id {
	my $self = shift;
	if(@_) {
		my $id = shift;
		die "Invalid state ID [$id]" unless exists $STATE_BY_ID{$id};
		return $self->state($STATE_BY_ID{$id});
	}
	return $self->{state_id};
}

=head2 in_state

Returns true if we're in the given state.

=cut

sub in_state {
	my $self = shift;
	my $expect = shift;
	die "Invalid state $expect" unless exists $VALID_STATES{$expect};
	return 1 if $self->state == $self->$expect;
	return 0;
}

=head2 C<write>

Raise an error if we call ->write at top level, just in case someone's trying to use this directly.

=cut

sub write {
	die "Attempted to call pure virtual method ->write, you need to subclass this and override this method\n";
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

__END__

=head1 AUTHOR

Tom Molesworth <cpan@entitymodel.com>

with thanks to Paul Evans <leonerd@leonerd.co.uk> for the L<IO::Async> framework, which provides
the foundation for L<Net::Async::IMAP>.

=head1 LICENSE

Licensed under the same terms as Perl itself.

