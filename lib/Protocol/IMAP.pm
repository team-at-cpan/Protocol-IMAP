package Protocol::IMAP;
# ABSTRACT: Support for RFC3501 Internet Message Access Protocol (IMAP4)
use strict;
use warnings;

use Encode::IMAPUTF7;
use Scalar::Util qw{weaken};
use Authen::SASL;

use Time::HiRes qw{time};
use POSIX qw{strftime};

our $VERSION = '0.001';

=head1 NAME

Protocol::IMAP - client support for the Internet Message Access Protocol as defined in RFC3501.

=head1 SYNOPSIS

 use Protocol::IMAP::Server;
 use Protocol::IMAP::Client;

=head1 DESCRIPTION

Base class for L<Protocol::IMAP::Server> and L<Protocol::IMAP::Client> implementations.

=head1 AUTHOR

Tom Molesworth <cpan@entitymodel.com>

with thanks to Paul Evans <leonerd@leonerd.co.uk> for the L<IO::Async> framework, which provides
the foundation for L<Net::Async::IMAP>.

=head1 LICENSE

Licensed under the same terms as Perl itself.

=head1 METHODS

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

=head2 C<debug>

Debug log message. Only displayed if the debug flag was passed to L<configure>.

=cut

sub debug {
	my $self = shift;
	return unless $self->{debug};

	my $now = Time::HiRes::time;
	warn strftime("%Y-%m-%d %H:%M:%S", gmtime($now)) . sprintf(".%03d", int($now * 1000.0) % 1000.0) . " @_\n";
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
