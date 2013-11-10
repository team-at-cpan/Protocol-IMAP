requires 'parent', 0;
requires 'Socket', 0;
requires 'Time::HiRes', 0;
requires 'POSIX', 0;
requires 'Encode::IMAPUTF7', 0;
requires 'Encode::MIME::EncWords', 0;
requires 'Authen::SASL', 0;
requires 'Mixin::Event::Dispatch', '>= 1.003';
requires 'Parser::MGC', 0;
requires 'Try::Tiny', 0;
requires 'curry', 0;
requires 'Future', 0;

on 'test' => sub {
	requires 'Test::More', '>= 0.98';
};

