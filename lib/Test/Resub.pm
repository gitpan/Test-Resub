# Copyright (c) 2001-2006, AirWave Wireless, Inc.
# This material contains trade secrets and confidential information of AirWave
# Wireless, Inc.
# Any use, reproduction, disclosure or dissemination is strictly prohibited
# without the explicit written permission of AirWave Wireless, Inc.
# All rights reserved.

use strict;
package Test::Resub;
use base qw(Exporter);

use Carp qw(croak);
use Class::Std;

our @EXPORT_OK = qw(resub);
our $VERSION = '1.00';

my %name :ATTR( :init_arg<name> );
my %capture :ATTR( :init_arg<capture>, :default(0) );
my %call_mode :ATTR( :init_arg<call>, :default('required') );
my %old_method :ATTR;
my %new_method :ATTR;
my %called :ATTR( :default(0) );
my %was_called :ATTR( :default(0) );
my %method_args :ATTR;

sub resub {
  my ($name, $code, %args) = @_;
  return Test::Resub->new({
    name => $name,
    code => $code,
    %args,
  });
}

sub default_replacement_sub { sub {} }

sub BUILD {
  my ($self, $ident, $args) = @_;

  my $code = $args->{code} || $self->default_replacement_sub;

  my $method = $args->{name};
  unless ($method =~ /^(\w+::)+\w+$/) {
    croak qq{bad method name "$method"!};
  }

  my $call_mode = $args->{call};
  my %is_valid = map { ($_ => 1) } qw(forbidden optional required);
  if ($call_mode and not $is_valid{$call_mode}) {
    croak sprintf(q{bad 'call' argument: %s (valid arguments are %s)},
      $call_mode, (join q{, }, sort keys %is_valid));
  }

  $new_method{$ident} = $code;
  $method_args{$ident} = [];
}
  
sub START {
  my ($self, $ident, $args) = @_;

  my $wrapper_code = sub {
    $called{$ident}++;
    $was_called{$ident}++;
    push @{$method_args{$ident}}, [@_] if $capture{$ident};
    return $new_method{$ident}->(@_);
  };
  {
    no strict 'refs';
    no warnings 'redefine';
    my $method = $name{$ident};
    my $orig_data = save_variables($method);
    $old_method{$ident} = defined *$method{CODE} ? \&$method : undef;
    *$method = $wrapper_code;
    restore_variables($method, $orig_data);
  }
}

sub DEMOLISH {
  my ($self, $ident) = @_;
  my $method = $name{$ident};
  return unless $method;        # happens if BUILD throws exception

  my $was_called = $was_called{$ident};
  if ( ($call_mode{$ident} eq 'forbidden' and $was_called) ||
      ($call_mode{$ident} eq 'required' and not $was_called) ) {
    print "not ok 1000\n";
    print '# ' . $method . ' ' .
      ($was_called ? 'called' : 'not called') . "\n" .
        Carp::longmess;
  }
    
  {
    no strict 'refs';
    no warnings 'redefine';

    my $existing_data = save_variables($method);
    if (not defined $old_method{$ident}) {
      my ($package, $name) = $self->split_package_method($method);
      delete ${ "$package\::" }{$name};
    } else {
      *$method = $old_method{$ident};
    }
    restore_variables($method, $existing_data);
  }
}

sub called {
  my ($self) = @_;
  return $called{ident $self};
}

sub was_called {
  my ($self) = @_;
  return $was_called{ident $self};
}

sub not_called {
  my ($self) = @_;
  return not $self->called;
}

sub reset {
  my ($self) = @_;
  my $ident = ident $self;
  $called{$ident} = 0;
  $method_args{$ident} = [];
}

sub args {
  my ($self) = @_;
  my $ident = ident $self;
  warn "Must use the 'capture' flag to capture arguments"
    unless $capture{$ident};
  return $method_args{$ident};
}

sub named_args {
  my ($self, %args) = @_;
  return $self->_named_things(
    sub { $self->args() },
    %args,
  );
}

sub method_args {
  my ($self) = @_;
  my $args = $self->args;
  return [map { my @tmp = @$_; shift @tmp; \@tmp } @$args];
}

sub named_method_args {
  my ($self, %args) = @_;
  return $self->_named_things(
    sub { $self->method_args() },
    %args,
  );
}

sub _named_things {
  my ($self, $retriever, %args) = @_;
  my $index = $args{arg_start_index} || $args{scalars} || 0;
  my $start_index = exists $args{arg_start_index} ? $index : 0;
  return [
    map { (@$_[$start_index..$index-1], { @$_[$index..$#$_] }) }
    @{$retriever->()}
  ]; 
}

sub save_variables {
  my ($varname) = @_;
  no strict 'refs';
  return {
    scalar => $$varname,
    array => \@$varname,
    hash => \%$varname,
  };
}

sub restore_variables {
  my ($varname, $data) = @_;
  no strict 'refs';
  $$varname = $data->{scalar};
  @$varname = @{$data->{array}};
  %$varname = %{$data->{hash}};
}

sub split_package_method {
  my ($self, $method) = @_;

  my ($package, $name) = $method =~ /^(.+)::([^:]+)$/;
  
  return ($package, $name);
}

1;

__END__

=head1 NAME

Test::Resub - Lexically scoped subroutine replacement for testing

=head1 SYNOPSIS

  #!/usr/bin/perl

  use Test::More tests => 4;
  use Test::Resub qw(resub);

  {
    package Somewhere;
    sub show {
      my ($class, $message) = @_;
      return "$class, $message";
    }
  }

  # sanity
  is( Somewhere->show('beyond the sea'), 'Somewhere, beyond the sea' );

  # scoped replacement of subroutine with argument capturing
  {
    my $rs = resub 'Somewhere::show', sub { 'hi' }, capture => 1;
    is( Somewhere->show('over the rainbow'), 'hi' );
    is_deeply( $rs->method_args, [['over the rainbow']] );
  }

  # scope ends, resub goes away, original code returns
  is( Somewhere->show('waiting for me'), 'Somewhere, waiting for me' );

=head1 DESCRIPTION

This module allows you to temporarily replace a subroutine/method with arbitrary
code.  Later, you can tell how many times was it called and
with what arguments each time.  You can also specify that the subroutine/method
must get called, must not get called, or may be optionally called.

=head1 CONSTRUCTOR

my $rs = resub 'package::method', sub { ... }, %args;

is equivalent to:

my $rs = Test::Resub->new(
  name => 'package::method',
  code => sub { ... },
  %args,
);

%args can be any of the following named arguments:

=over 4

=item B<name>

The function/method which is to be replaced.

=item B<code>

The code reference which will replace C<name>.  Defaults to C<sub {}>

=item B<capture>

Boolean which indicates whether or not arguments should be captured.
A warning is emitted if you try to look at args without specifying a "true"
C<capture>.  Defaults to 0.

=item B<call>

One of the following values (defaults to 'required'):

=over 4

=item B<required>

If the subroutine/method was never called when the Test::Resub object is
destroyed, "not ok 1000" is printed to STDOUT.

=item B<forbidden>

If the subroutine/method was called when the Test::Resub object is
destroyed, "not ok 1000" is printed to STDOUT.

=item B<optional>

It doesn't matter if the subroutine/method gets called.  As a general rule,
your tests should know whether or not a subroutine/method is going to get
called, so avoid using this option if you can.

=back

=back

=head1 METHODS

=over 4

=item B<called>

Returns the number of times the replaced subroutine/method was called.  The
C<reset> method clears this data.

=item B<was_called>

Returns the total number of times the replaced subroutine/method was called.
This data is B<not> cleared by the C<reset> method.

=item B<not_called>

Returns true if the replaced subroutine/method was never called.  The C<reset>
method clears this data.

=item B<reset>

Clears the C<called>, C<not_called>, and C<args> data.

=item B<args>

Returns data on how the replaced subroutine/method was invoked.  Examples:

  Invocations:                             C<args> returns:
  ----------------------------             -------------------------
    (none)                                   []
    foo('a');                                [['a']]
    foo('a', 'b'); foo('d');                 [['a', 'b'], ['d']]

=item B<named_args>

Like C<args>, but each invocation's arguments are returned in a hashref.
Examples:

  Invocations:                             C<named_args> returns:
  ----------------------------             -------------------------
   (none)                                   []
   foo(a => 'b');                           [{a => 'b'}]

   foo(a => 'b', c => 'd'); foo(e => 'f');
                                            [{
                                              a => 'b', c => 'd',
                                            }, {
                                              e => 'f',
                                            }]

The C<arg_start_index> argument specifes that a certain number of
arguments are to be discarded. For example:
  my $rs = resub 'some_sub';
  ...
  some_sub('one', 'two', a => 1, b => 2);
  ...
  $rs->named_args(arg_start_index => 1);
  # returns ['two', {a => 1, b => 2}]

  $rs->named_args(arg_start_index => 2);
  # returns [{a => 1, b => 2}]


The C<scalars> argument specifies that a certain number of scalar
arguments precede the key/value arguments.  For example:

  my $rs = resub 'some_sub';
  ...
  some_sub(3306, a => 'b', c => 123);
  some_sub(9158, a => 'z', c => 456);
  ...
  $rs->named_args(scalars => 1);
  # returns [3306, {a => 'b', c => 123},
  #          9158, {a => 'z', c => 456}]

Note that C<named_args(scalars => N)> will yield N scalars plus one hashref
per call regardless of how many arguments were passed to the
subroutine/method. For example:

  my $rs = Test::Resub->new({name => 'some_sub'});
  ...
  some_sub('one argument only');
  some_sub('many', 'arguments', a => 1, b => 2);
  ...
  $rs->named_args(scalars => 2);
  # returns ['one argument only', undef, {},
  #          'many', 'arguments', {a => 1, b => 2}]

=item B<method_args>

Like C<args>, but the first argument of each invocation is thrown away.
This is used when you're
resub'ing an object or class method and you're not interested in testing the
object or class argument.  Examples:

  Invocations:                             C<method_args> returns:
  ----------------------------             -------------------------
    (none)                                   []
    $obj->foo('a');                          [['a']]
    Class->foo('a', 'b'); Class->foo('d');   [['a', 'b'], ['d']]

=item B<named_method_args>

Like C<named_args>, but the first argument of each invocation is thrown away.
This is used when you're resub'ing an object or class method and the arguments
are name/value pairs.  Examples:

  Invocations:                             C<named_args> returns:
  ----------------------------             -------------------------
   (none)                                   []
   $obj->foo(a => 'b');                     [{a => 'b'}]

   $obj->foo(a => 'b', c => 'd');           [{
   Class->foo(e => 'f');                      a => 'b', c => 'd',
                                            }, {
                                              e => 'f',
                                            }]

C<named_method_args> also takes a "scalars" named argument which specifies
a number of scalar arguments preceding the name/value pairs of each invocation.
It works just like C<named_args> except that the first argument of each
invocation is automatically discarded.
For example:

  my $rs = resub 'SomeClass::some_sub';
  ...
  SomeClass->some_sub(3306, a => 'b', c => 123);
  SomeClass->some_sub(9158, a => 'z', c => 456);
  ...
  $rs->named_method_args(scalars => 1);
  # returns [3306, {a => 'b', c => 123},
  #          9158, {a => 'z', c => 456}]

Note: the first argument is automatically discarded B<before> the optional 
C<arg_start_index> parameter is applied. That is,

  my $rs = resub 'SomeClass::some_sub';
  ...
  SomeClass->some_sub('first', b => 2);
  ...
  $rs->named_method_args(arg_start_index => 1);
  # returns [{b => 2}]

=back

=head1 HISTORY

Written at AirWave Wireless for internal testing, 2001-2007.  Tidied up and
released to CPAN in 2007.

=head1 AUTHORS

The development team at AirWave Wireless, L<http://www.airwave.com/>.
Please direct questions, comments, bugs, patches, etc. to F<cpan@airwave.com>.

=cut
