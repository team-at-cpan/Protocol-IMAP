package Protocol::IMAP::Address;
use strict;
use warnings;

=head1 NAME

Protocol::IMAP::Address - represents an email address as found in the message envelope

=cut

use overload
	'""' => 'to_string',
	bool => sub() { 1 },
	fallback => 1;

sub new {
	my $class = shift;
	my %args = @_;
	my $self = bless \%args, $class;
	$self
}

sub mailbox { shift->{mailbox} }
sub host { shift->{host} }
sub name { shift->{name} }
sub source { shift->{source} }

sub to_string {
	my $self = shift;
	join '@', $self->mailbox, $self->host
}

1;
