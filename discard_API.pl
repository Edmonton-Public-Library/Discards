#!/usr/bin/env perl
########################################################################
# Purpose: Processes API calls for the discard process.
# Method:  Requests are submitted as well formed rest calls and the responses
#          are returned as well formed XML responses.
#
# Author:  Andrew Nisbet, Edmonton Public Library
# Date:    December 14, 2012
# Rev:     0.0 - develop
#          
########################################################################

use strict;
use warnings;
use vars qw/ %opt /;
use Getopt::Std;

my $VERSION   = '0.0';
my $LAST_COPY = {};

$LAST_COPY->{'ITEM'} = qq{};

# Message about this program and how to use it
#
sub usage()
{
    print STDERR << "EOF";

This script manages API calls to the discard process.

usage: $0 [-x] [-l keyword]

Each request is passed by catagory such as bills, with a modifier keyword that describes the 
type of information requested. Example -l ITEMS would return all the items in the exceptions file
for last copy and last copy with holds as xml.

 -l [keyword] : Get [keyword] information about last copies. Keywords include [ITEMS, HOLDS, ORDERS].
 -x : this (help) message

 Version: $VERSION
EOF
    exit;
}

# Kicks off the setting of various switches.
# param:
# return:
sub init()
{
    my $opt_string = 'b:h:l:o:x';
    getopts( "$opt_string", \%opt ) or usage();
    usage() if ($opt{x});
	print "$opt{'l'}\n\n" if ( $opt{'l'} );
}


init();

