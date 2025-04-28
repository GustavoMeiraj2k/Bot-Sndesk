#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use UNIVERSAL::require;
use English qw(-no_match_vars);

use GLPI::Agent::Tools;

use constant    LISTED_CATEGORY_COUNT   => 37;

plan(skip_all => 'Author test, set $ENV{TEST_AUTHOR} to a true value to run')
    if !$ENV{TEST_AUTHOR};

# Check all categtories are listed in glpi-agent pod part

plan tests => 2;

my %categories;
foreach my $line (getAllLines(command => "bin/glpi-agent --list-categories")) {
    chomp($line);
    next unless $line =~ /^ - (.+)$/;
    $categories{$1} = 1;
}

my $count = scalar keys(%categories);
ok($count == LISTED_CATEGORY_COUNT, "Listed categories count: $count should be ".LISTED_CATEGORY_COUNT);

foreach my $line (getAllLines(file => "bin/glpi-agent")) {
    chomp($line);
    next unless $line =~ /^=item \* (.+)$/;
    delete $categories{$1};
}

my @missing = keys(%categories);

map { warn "Category '$_' is missing in bin/glpi-agent pod\n" } @missing;

ok(scalar(@missing) == 0, "Listed categories in bin/glpi-agent");
