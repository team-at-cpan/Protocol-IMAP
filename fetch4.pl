#!/usr/bin/env perl 
use strict;
use warnings;
++$|;

{

package ResponseParser;
use 5.010;
use Future;
use List::Util qw(min);

sub new {
	my $class = shift;
	bless {
		tasks => [],
		@_
	}, $class
}

=pod

We provide a hierarchy of tasks:

 list
  keywords:
   DATE => ...
   ENVELOPE => ...

Each task provides a future and optionally a callback for processing larger volumes of data (BODY, for example).

=cut

=head2 skip_ws

Read past any whitespace in the buffer.

If we find something that's non-whitespace, removes the current handler.

=cut

sub skip_ws {
	my ($self) = @_;
	/\G\s*/gc;
	pop @{$self->{handler}} if /\G(?=[^\s])/gc
}

=head1 METHODS - Internal

=head2 future

Returns a new L<Future>.

=cut

sub new_future { Future->new }

=head2 string

Once we find a string, we emit it with the associated label:

 string 'some_label' ==> 'some_label', 'actual value'

=cut

sub string {
	my ($self, $label) = @_;

	my $started = 0;
	my $f = $self->new_future;
	my %spec; 
	$f->on_done(sub {
		my ($label, $str) = @_;
		say "$label was: " . ($str // 'undef');
		# $self->{data}{$label} = $str;
	});
	%spec = (
		code => sub {
			if(ref $_) {
				$f->done($label => $$_);
				return;
			}

			# Should we skip whitespace here? Seems that it's not strictly required.
			# 1 if /\G\s*/gc;

			# Null string is represented as undef
			if(/\GNIL(?=[^\w])/gc) {
				$f->done($label => undef);
				return;
			} elsif(/\G\{(\d+)\}\x0D\x0A/gc) {
				$spec{remaining} = $1;
				return;
			} elsif(/\G"/gc) {
				# so we had a " character, which means we're expecting a quoted
				# string rather than a literal... we just need to keep reading until
				# we hit a trailing " character.
				my $txt = '';
				while(1) {
					warn "check text: [" . substr($_, pos) . "]\n";
					# Quoted \ and " chars first
					if(/\G\\(["\\])/gc) {
						$txt .= $1;
					} elsif(/\G([^"\\]+)/gc) {
						$txt .= $1;
					} elsif(/\G"/gc) {
						warn "Finished: [$txt] and [" . substr($_, pos) . "]\n";
						$f->done($label => $txt);
						return;
					} elsif(/\G./gcs) {
						die "unexpected character in literal string: [" . substr($_, pos) . "]";
					}
				}
			} else {
				die "Not a string for $label?: [" . substr($_, pos // 0) . "]";
			}
		},
		completion => $f
	);
	push @{$self->{tasks}}, \%spec;
}

sub num {
	my ($self, $label) = @_;
	my $started = 0;
	my $f = $self->new_future;
	my %spec; %spec = (
		code => sub {
			if(/\G(\d+)(?=[^\d])/gc) {
				$f->done($label => 0+$1);
				return;
			} else {
				die "Invalid number"
			}
		},
		completion => $f
	);
	push @{$self->{tasks}}, \%spec;
}

sub flag {
	my ($self) = @_;
	my $started = 0;
	my $f = $self->new_future;
	my %spec; %spec = (
		code => sub {
			if(/\G([a-z0-9\\]+)(?=[^a-z0-9\\])/gci) {
				say "Flag found: $1";
				$f->done(flags => [$1]);
				return;
			} else {
				die "Invalid flag"
			}
		},
		completion => $f
	);
	push @{$self->{tasks}}, \%spec;
}

sub group {
	my ($self, $code, $label) = @_;
	my @t;
	{
		local $self->{tasks} = \@t;
		$self->$code();
	}
	my $f = $self->new_future;
	my %spec; %spec = (
		code => sub {
			if($spec{old}) {
				if(/\G\)/gc) {
					say "End of group";
					$self->{tasks} = delete $spec{old};
					say "Parent had " . @{$self->{tasks}} . " pending";
					$f->done;
					return;
				} else {
					die ") not found"
				}
			}
			if(/\G\(/gc) {
				say "Start of group";
				$spec{old} = $self->{tasks};
				$self->{tasks} = [ @t, \%spec ];
				return;
			} else {
				die "( not found for $label"
			}
		},
		completion => $f,
	);
	push @{$self->{tasks}}, \%spec;
}

sub sequence {
	my ($self, $code, $label) = @_;
	my @t;
	{
		local $self->{tasks} = \@t;
		$self->$code();
	}
	my $f = $self->new_future;
	my %spec; %spec = (
		code => sub {
			if($spec{old}) {
				say "End of sequence $label";
				$self->{tasks} = delete $spec{old};
				say "Parent had " . @{$self->{tasks}} . " pending";
				$f->done;
				return;
			}
			say "Start of sequence $label";
			$spec{old} = $self->{tasks};
			$self->{tasks} = [ @t, \%spec ];
			return;
		},
		completion => $f,
	);
	push @{$self->{tasks}}, \%spec;
}

sub list {
	my ($self, $code) = @_;
	my @pending;
	{
		my @t;
		local $self->{tasks} = \@t;
		$self->$code();
		push @pending, map $_->{completion}, @t;
	}
	my $f = $self->new_future->on_done(sub {
		say "List completion: data was @_";
	});
	my %spec;
	%spec = (
		code => sub {
			say "In list process";
			if($spec{old}) {
				if(/\G\)/gc) {
					say "End of list";
					$self->{tasks} = $spec{old};
					$f->done(map $_->{completion}->get, @t);
					return;
				} else {
					say "Not finished yet: @t";
					$self->skip_ws;
					my @t;
					{
						local $self->{tasks} = \@t;
						$self->$code();
						push @pending, map $_->{completion}, @t;
					}
					$self->{tasks} = [ @t, \%spec ];
					return;
				}
			}
			if(/\G\(/gc) {
				say "Start of list";
				$spec{old} = $self->{tasks};
				$self->{tasks} = [ @t, \%spec ];
				return;
			} else {
				die "( not found"
			}
		},
		completion => $f,
	);
	push @{$self->{tasks}}, \%spec;
	\%spec
}

sub addresslist {
	my ($self, $label) = @_;
	my $f = $self->new_future;
	my %spec; %spec = (
		code => sub {
			if(/\GNIL/gc) {
				$f->done(
					$label => undef
				);
				return;
			}
			my @t;
			{
				local $self->{tasks} = \@t;
				$self->group(sub {
					my ($self) = @_;
					$self->group(sub {
						my ($self) = @_;
						$self->string('name');
						$self->string('smtp');
						$self->string('mailbox');
						$self->string('host');
					}, $label);
				});
			}
			$self->{tasks} = \@t;
		},
		completion => $f,
	);
	push @{$self->{tasks}}, \%spec;
}

sub potential_keywords {
	my ($self, $kw) = @_;
	my $f = $self->new_future;
	my %spec; %spec = (
		code => sub {
			if($spec{old}) {
				$self->{tasks} = delete $spec{old};
				$f->done;
				return;
			}
			if(/\G([a-z0-9.]+)(?=\s)/gci) {
				my $k = $1;
				say "Found keyword: $k";
				die "Unknown keyword $k" unless exists $kw->{$k};
				$self->skip_ws;
				$spec{old} = $self->{tasks};
				my @t;
				{
					local $self->{tasks} = \@t;
					my $code = $kw->{$k};
					$self->$code();
				}
				{
					my $ff = Future->wait_all(map $_->{completion}, @t)->then(sub {
						my @rslt = map $_->get, @_;
						warn "KW Had @rslt for $k\n";
						# ($data->{$k}) = @rslt;
						Future->wrap(@rslt)
					});
					$ff->on_ready(sub { undef $ff });
				}
				$self->{tasks} = [ @t, \%spec ];
				return;
			} # else { die "No keyword" }
		},
		completion => $f,
	);
	push @{$self->{tasks}}, \%spec;
}

sub process {
	my ($self, $chunk) = @_;
	say "add " . length($chunk) . " chars";
	push @{$self->{pending}}, $chunk;

	my %result;
	while(@{$self->{pending}}) {
		my $next = shift @{$self->{pending}};
		for($next) {
			ITER: {
			warn "Iter with [$_]\n";
			# If we're collecting data, add this bit as well
			if(defined($self->{buffer})) {
				my $task = $self->{tasks}[0];
				$self->{buffer} .= substr $_, 0, min($self->{required}, length($self->{buffer}) + length($_)), '';
				warn "Bufefr is now [" . $self->{buffer} . "]\n";
				if(length($self->{buffer}) == $self->{required}) {
					$task->{completion}->done(delete $self->{buffer});
					shift @{$self->{tasks}};
					$self->skip_ws;
					warn "=> After remaining block, we skipped to [" . substr($_, pos($_) // 0) . "]\n";
					redo ITER;
				}
			}

			# pos can be undef at the start or if we had an earlier failed match
			THING:
			while((pos($_) // 0) < length) {
				if(@{$self->{tasks}}) {
					my $task = $self->{tasks}[0];
					$task->{code}->();
					if($task->{completion}->is_ready) {
						if(my ($k, $v) = (shift @{$self->{tasks}})->{completion}->get) {
							if(ref $v) {
								push @{$result{$k}}, @$v;
							} else {
								$result{$k} = $v;
							}
						}
						$self->skip_ws;
					} elsif(exists $task->{remaining}) {
						$self->{required} = $task->{remaining};
						say "Not ready yet - remaining: " . $self->{required};
						# Remove everything we've processed so far
						substr $_, 0, pos($_), '';
						warn ">> now have [$_]\n";

						$self->{buffer} = substr $_, 0, min($self->{required}, length), '';
						if(length($self->{buffer}) == $self->{required}) {
							$task->{completion}->done($self->{buffer});
							shift @{$self->{tasks}};
							$self->skip_ws;
							warn "=> After remaining block, we skipped to [" . substr($_, pos($_) // 0) . "]\n";
							last THING;
						} else {
							last THING;
						}
					}
				} else {
					say "Finished";
					last THING
				}
			}
			}
		}
	}
}

sub extract_result {
	my ($self) = @_;
	delete $self->{data};
}

}

=pod

->list ==> arrayref
->flag ==> string
->string ==> k, v
->group ==> hashref

We also have higher-level constructs:

->potential_keywords ==> hashref
->addresslist ==> k, v

 [
  FLAGS => [ ... ]
  ENVELOPE => {

  }
 ]

=cut

my $parser = ResponseParser->new;
my $f = $parser->list(sub {
	my ($parser) = @_;
	# We expect to see zero or more of these, order doesn't seem
	# to be too important either.
	$parser->potential_keywords({
		# We can have zero or more flags
		'FLAGS'          => sub {
			my ($parser) = @_;
			$parser->list(sub {
				my ($parser) = @_;
				$parser->flag
			})
		},
		'BODY'           => sub { },
		'BODYSTRUCTURE'  => sub { },
		'ENVELOPE'       => sub {
			my ($parser) = @_;
			$parser->group(sub {
				my ($parser) = @_;
				$parser->string('date');
				$parser->string('subject');
				$parser->addresslist('from');
				$parser->addresslist('sender');
				$parser->addresslist('reply_to');
				$parser->addresslist('to');
				$parser->addresslist('cc');
				$parser->addresslist('bcc');
				$parser->string('in_reply_to');
				$parser->string('message_id');
			})
		},
		'INTERNALDATE'   => sub {
			my ($parser) = @_;
			$parser->string('internaldate')
		},
		'UID'            => sub {
			my ($parser) = @_;
			$parser->num('uid')
		},
		'RFC822.SIZE'    => sub {
			my ($parser) = @_;
			$parser->num('size')
		},
	})
})->{completion};

my @pending = (qq!(FLAGS (\\Seen Junk) INTERNALDATE "24-Feb-2012 17:41:19 +0000" RFC822.SIZE 1234 ENVELOPE ({31}\x0D\x0A!, qq!Fri, 24 Feb 2012 12:41:15 -0500 "[rt.cpan.org #72843] GET.pl example fails for reddit.com " (("Paul Evans via RT" NIL "bug-Net-Async-HTTP" "rt.cpan.org")) (("Paul Evans via RT" NIL "bug-Net-Async-HTTP" "rt.cpan.org")) ((NIL NIL "bug-Net-Async-HTTP" "rt.cpan.org")) ((NIL NIL "TEAM" "cpan.org")) ((NIL NIL "kiyoshi.aman" "gmail.com")) NIL "" "<rt-3.8.HEAD-10811-1330105275-884.72843-6-0\@rt.cpan.org>"))\x0D\x0A!);
$parser->process($_) for @pending;

use JSON::MaybeXS;
use feature qw(say);
say JSON::MaybeXS->new(pretty => 1)->encode($f->get); # parser->extract_result);

