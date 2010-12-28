package Protocol::IMAP;
# ABSTRACT: Support for the Internal Mailbox Access Protocol
use strict;
use warnings;

use Encode::IMAPUTF7;
use Scalar::Util qw{weaken};
use Authen::SASL;

our $VERSION = '0.001';

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

1;
