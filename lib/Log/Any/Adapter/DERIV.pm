package Log::Any::Adapter::DERIV;
# ABSTRACT: one company's example of a standardised logging setup

use strict;
use warnings;

# AUTHORITY
our $VERSION = '0.001';

use parent qw(Log::Any::Adapter::Coderef);

use utf8;

=encoding utf8

=head1 NAME

Log::Any::Adapter::DERIV - standardised logging to STDERR and JSON file

=head1 DESCRIPTION

Applies some opinionated log handling rules for L<Log::Any>.

B<This is extremely invasive>. It does the following, affecting global state
in various ways:

=over 4

=item * applies UTF-8 encoding to STDERR

=item * writes to a C<.json.log> file named for the current process

=item * overrides the default L<Log::Any::Proxy> formatter to provide data as JSON

=item * when stringifying, may replace some problematic objects with simplified versions

=back

An example of the string-replacement approach would be the event loop in asynchronous code:
it's likely to have many components attached to it, and dumping that would effectively end up
dumping the entire tree of useful objects in the process. This is a planned future extension,
not currently implemented.

=head2 Why

This is provided as a CPAN module as an example for dealing with multiple outputs and
formatting. The existing L<Log::Any::Adapter> modules tend to cover one thing, and it's
not immediately obvious how to extend formatting, or send data to multiple logging mechanisms
at once.

Although the module may not be directly useful, it is hoped that other teams may find
parts of the code useful for their own logging requirements.

There is a public repository on Github, anyone is welcome to fork that and implement
their own version or make feature/bugfix suggestions if they seem generally useful:

L<https://github.com/binary-com/perl-Log-Any-Adapter-DERIV>

=cut

use Time::Moment;
use Path::Tiny;
use curry;
use JSON::MaybeUTF8 qw(:v1);
use PerlIO;
use Term::ANSIColor;
use Log::Any qw($log);

# Used for stringifying data more neatly than Data::Dumper might offer
our $JSON = JSON::MaybeXS->new(
    # Multi-line for terminal output, single line if redirecting somewhere
    pretty          => (-t STDERR),
    # Be consistent
    canonical       => 1,
    # Try a bit harder to give useful output
    convert_blessed => 1,
);

# Simple mapping from severity levels to Term::ANSIColor definitions.
our %SEVERITY_COLOUR = (
    trace    => [qw(grey12)],
    debug    => [qw(grey18)],
    info     => [qw(green)],
    warning  => [qw(bright_yellow)],
    error    => [qw(red bold)],
    fatal    => [qw(red bold)],
    critical => [qw(red bold)],
);

# The obvious way to handle this might be to provide our own proxy class:
#     $Log::Any::OverrideDefaultProxyClass = 'Log::Any::Proxy::DERIV';
# but the handling for proxy classes is somewhat opaque - and there's an ordering problem
# where `use Log::Any` before the adapter is loaded means we end up with some classes having
# the default anyway.
# Rather than trying to deal with that, we just provide our own default:
{
    no warnings 'redefine';

    # We expect this to be loaded, but be explicit just in case - we'll be overriding
    # one of the methods, so let's at least make sure it exists first
    require Log::Any::Proxy;

    # Mostly copied from Log::Any::Proxy
    *Log::Any::Proxy::_default_formatter = sub {
        my ( $cat, $lvl, $format, @params ) = @_;
        return $format->() if ref($format) eq 'CODE';

        chomp(
            my @new_params = map {
                eval { $JSON->encode($_) } // Log::Any::Proxy::_stringify_params($_)
            } @params
        );
        s{\n}{\n  }g for @new_params;

        # Perl 5.22 adds a 'redundant' warning if the number parameters exceeds
        # the number of sprintf placeholders.  If a user does this, the warning
        # is issued from here, which isn't very helpful.  Doing something
        # clever would be expensive, so instead we just disable warnings for
        # the final line of this subroutine.
        no warnings;
        return sprintf( $format, @new_params );
    };
}

# Upgrade any `warn ...` lines to send through Log::Any.
$SIG{__WARN__} = sub {
    # We don't expect anything called from here to raise further warnings, but
    # let's be safe and try to avoid any risk of recursion
    local $SIG{__WARN__} = undef;
    chomp(my $msg = shift);
    $log->warn($msg);
};

# Upgrade any `die...` lines to send through Log::Any.
$SIG{__DIE__} = sub {
    chomp(my $msg = shift);
    my $i = 1;
    # will ignore if die is in eval or try block
    while ( (my @call_details = (caller($i++))) ){
        return if $call_details[3] eq '(eval)';
    }
    $log->error($msg);
};

sub new {
    my ( $class, %args ) = @_;
    $args{colour} //= -t STDERR;
    my $self = $class->SUPER::new(sub { }, %args);

    # There are other ways of running containers, but for now "in docker? generate JSON"
    # is at least a starting point.
    $self->{in_container} = -r '/.dockerenv';
    my $json_log_file = $self->{json_log_file};
    $json_log_file = $0 . '.json.log' if(!$json_log_file && !$self->{in_container});
    if($json_log_file) {
        $self->{fh} = path($json_log_file)->opena_utf8 or die 'unable to open log file - ' . $!;
        $self->{fh}->autoflush(1);
    }

    # Keep a strong reference to this, since we expect to stick around until exit anyway
    $self->{code} = $self->curry::log_entry;
    return $self;
}

sub apply_filehandle_utf8 {
    my ($class, $fh) = @_;
    # We'd expect `encoding(utf-8-strict)` and `utf8` if someone's already applied binmode
    # for us, but implementation details in Perl may change those names slightly, and on
    # some platforms (Windows?) there's also a chance of one of the UTF16LE/BE variants,
    # so we make this check quite lax and skip binmode if there's anything even slightly
    # utf-flavoured in the mix.
    $fh->binmode(':encoding(UTF-8)')
        unless grep /utf/i, PerlIO::get_layers($fh, output => 1);
    $fh->autoflush(1);
}

sub format_line {
    my ($class, $data, $opts) = @_;
    # With international development teams, no matter which spelling we choose
    # someone's going to get this wrong sooner or later... or to put another
    # way, we got country *and* western.
    $opts->{colour} = $opts->{color} || $opts->{colour};

    # Expand formatting if necessary: it's not immediately clear how to defer
    # handling of structured data, the ->structured method doesn't have a way
    # to return the stringified data back to the caller for example
    # for edge cases like `my $msg = $log->debug(...);` so we're still working
    # on how best to handle this:
    # https://metacpan.org/release/Log-Any/source/lib/Log/Any/Proxy.pm#L105
    # $_ = sprintf $_->@* for grep ref, $data->{message};

    # If we have a stack entry, report the context - default to "main" if we're at top level
    my $from = $data->{stack}[-1] ? join '->', @{$data->{stack}[-1]}{qw(package method)} : 'main';

    # Start with the plain-text details
    my @details = (
        Time::Moment->from_epoch($data->{epoch})->strftime('%Y-%m-%dT%H:%M:%S%3f'),
        uc(substr $data->{severity}, 0, 1),
        "[$from]",
        $data->{message},
    );

    # This is good enough if we're in non-colour mode
    return join ' ', @details unless $opts->{colour};

    my @colours = ($SEVERITY_COLOUR{$data->{severity}} || die 'no severity definition found for ' . $data->{severity})->@*;

    # Colour formatting codes applied at the start and end of each line, in case something else
    # gets inbetween us and the output
    local $Term::ANSIColor::EACHLINE = "\n";
    my ($ts, $level) = splice @details, 0, 2;
    $from = shift @details;
    return join ' ',
        colored(
            $ts,
            qw(bright_blue),
        ),
        colored(
            $level,
            @colours,
        ),
        colored(
            $from,
            qw(grey10)
        ),
        map {
            colored(
                $_,
                @colours,
            ),
        } @details;
}

sub log_entry {
    my ($self, $data) = @_;

    unless($self->{has_stderr_utf8}) {
        $self->apply_filehandle_utf8(\*STDERR);
        $self->{has_stderr_utf8} = 1;
    }

    $self->{fh}->print(encode_json_text($data) . "\n") if $self->{fh};

    my $txt = $self->{in_container} # docker tends to prefer JSON
    ? encode_json_text($data)
    : $self->format_line($data, { colour => $self->{colour} });

    # Regardless of the output, we always use newline separators
    STDERR->print(
        "$txt\n"
    );
}

1;

=head1 AUTHOR

Deriv Group Services Ltd. C<< DERIV@cpan.org >>

=head1 LICENSE

Copyright Deriv Group Services Ltd 2020-2021. Licensed under the same terms as Perl itself.

