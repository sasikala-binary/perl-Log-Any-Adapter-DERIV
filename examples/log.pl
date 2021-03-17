#!/usr/bin/env perl 
use strict;
use warnings;

use Log::Any::Adapter qw(DERIV);
use Log::Any qw($log);

sub example_sub {
    $log->infof('Info level');
}
$log->trace('Trace level');
$log->debugf('Debug level, with simple hashref: %s', { xyz => 123 });
$log->infof('Info level');
example_sub();
$log->warnf('Warning level');
$log->errorf('Error level');
warn "regular warn line\n";
$log->fatalf('Fatal level', { extra => 'data' });

$log->infof('Nested data structure %s', { arrayref => ['a'..'f'], hashref => { another => { hashref => 'here' } } });

