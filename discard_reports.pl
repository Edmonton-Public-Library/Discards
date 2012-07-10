#!/usr/bin/env perl
########################################################################
# Purpose: Get results of discard reports.
# Method:  The script reads the printlist searching for Convert discards
#          reports for a user specified day (default: today). It then
#          searches for the day's remove_discard_items report to retrieve
#          the daily removed items total. Much of this code is reusable
#          for the Morning stats reporting. All results and statuses are
#          printed to STDOUT like so:
#
# CSDCA6 status: OK, 0 items converted.
# CSDCA7 status: OK, 0 items converted.
# HIGCA1 status: OK, 136 items converted.
# HIGCA3 status: OK, 113 items converted.
# IDYCA1 status: OK, 0 items converted.
# IDYCA3 status: OK, 1332 items converted.
#Total convert candidates: 1542
#Total removed: 1284 of 1542 candidates.
#
# There is a -w option to wait 'n' seconds for the remove report to finish,
# a -m option to have the results mailed to you, -x for help and -d to
# specify results from a different day, so we can quickly review old
# reports.  The script does not set any side effects either in
# Symphony or EPLAPP.
#
# Author:  Andrew Nisbet
# Date:    April 2, 2012
# Rev:     0.0 - develop
#          1.0 - April 4, 2012 - initial testing on eplapp.
#          1.1 - April 5, 2012 - added converted candidate's total updated
#          documentation.
#          1.2 - April 18, 2012 - added verbose flag and output now
#          defaults to pipe delimited output.
#          1.3 - Fixed merge to accomodate the addtitional user key in
#          finished_discards.txt.
#          1.03 - Bug fix that computed name was not updating overly-long
#          card name like MNA-DISCARDCA10.
#          1.03.5- Fixed output to include '|' for non-verbose output and
#          added ceiling on percent completion reporting output.
########################################################################

use strict;
use warnings;
use vars qw/ %opt /;
use Getopt::Std;
use POSIX qw/ceil/;
# Use this for writing files to EPLAPP.
# use Fcntl;          # Needed for sysopen flags O_WRONLY etc.

#
# Message about this program and how to use it
#
sub usage()
{
    print STDERR << "EOF";

This script takes the DISCARD reports for a specific day (today by default)
and prints the results to STDOUT.

usage: $0 [-x] [-d ascii_date] [-m email] [-w num_seconds] -g [finished_list]

 -d yyyymmdd : checks the reports for a specific day (ASCII date format)
 -g file     : merge the results with an existing DISCARDS table file produced
               by discard.pl.
 -m addrs    : mail output to provided address
 -x          : this (help) message
 -v          : verbose otherwise pipe delimited 'card|total converted'.
 -w secs     : wait the maximum of 'n' seconds for remove report to finish
               before exiting.

example: $0 -d 20120324 -m anisbet\@epl.ca -w 240

EOF
    exit;
}

# use this next line for production.
my $listDir = `getpathname rptprint`;
chomp($listDir);
my $PRINT_LIST = "$listDir/printlist";
#my $PRINT_LIST = "printlist"; # Test path
#my $date = "20120402";
my $date = `transdate -d+0`;
chomp($date);
my $convertSuccessCode = qq{"(1302)"};
my $convertReportTitle = qq{"Convert DISCARD Items "};
my $address     = qq{};

# Kicks off the setting of various switches.
# param:
# return:
sub init()
{
    my $opt_string = 'xvd:g:m:w:';
    getopts( "$opt_string", \%opt ) or usage();
    usage() if ($opt{x});
    $date = $opt{'d'} if ($opt{'d'});
}

init();
my $mail = "";
my $convertDiscardCmd = qq{grep -h $convertReportTitle $PRINT_LIST |};
open(GREP_REPORT_NAME,$convertDiscardCmd) || die "Failed: $!\n";
my $convertGTotal = 0;
my %mergeData;
while ( <GREP_REPORT_NAME> )
{
    my @cols = split('\|', $_);
    # field 5 (0 indexed) contains the last run date.
    #print $cols[0].":".substr($cols[2], 0, 8)."\n";
    # if the time stamp the report ran matches the specified day (ascii).
    if (substr($cols[2], 0, 8) eq $date)
    {
        # This is the printlist entry:
        #vszd|Convert DISCARD Items CSDCA3|201202080921|OK|ADMIN|cvtdiscard|0||
        # get it from the rptprint directory/mmny.log
        my $library = qq{grep -h $convertReportTitle $listDir/$cols[0].log |};
        my $myLibrary = "";
        open(GREP_LIBRARY, $library) || die "Failed: $!\n";
        while (<GREP_LIBRARY>)
        {
            $myLibrary = substr($_, (rindex($_, " ") +1), length($_) -1);
            chomp($myLibrary);

        }
        close(GREP_LIBRARY);
        # our goal:
        # CardName      |Description          |DateCreate|DateLastUsed|Oncard|Converted
        # CPL-DISCARDCA5|CPL-DISCARD CAT ITEMS|5/4/2009  |6/3/2011    |324   |189
        # all of that needs to come from:
        # seluser -p"DISCARD" -y"EPLCSD" -oUBDfachb | seluserstatus -iU -oSj
        # but we can get Converted and report a status:
        my $getResults = qq{grep -h $convertSuccessCode /s/sirsi/Unicorn/Rptprint/$cols[0].log |};
        open(GREP_CONVERTED, $getResults) || die "Failed: $!\n";
        while (<GREP_CONVERTED>)
        {
            # to get here entry looks like: 257 <$item> $(1302)
            # now clean the record by removing the codes
            my $totalConverted = substr($_, 0, index($_, "<") -1);
            $totalConverted =~ s/^\s+//;
            $totalConverted =~ s/\s+$//;
            if ($opt{v})
            {
                print "$myLibrary status: $cols[3], $totalConverted items converted.\n";
            }
            else
            {
                print "$myLibrary|$totalConverted|\n";
            }
            $mergeData{$myLibrary} = $totalConverted;
            $convertGTotal += $totalConverted;
            $mail .= "$myLibrary status: $cols[3], $totalConverted items converted.\n";
        }
        close(GREP_CONVERTED);
    }
}
close(GREP_REPORT_NAME);
if ($opt{v})
{
    print "Total convert candidates for $date: $convertGTotal\n";
}
my $removeSuccessCode = qq{"(1409)"};
my $removeReportTitle = qq{remove_discard_items};
my $removeDiscardCmd  = qq{grep -h $removeReportTitle $PRINT_LIST |};
# Here we Merge the output with the finished discards table.
if ($opt{g})
{
    my $tmpFile = "dr.tmp";
	my $updated = 0;
	my $totalUpdated = 0;
	my $total = 0;
    open(DISCARD_LIST, "+>>", $opt{'g'}) || die "Could not merge $opt{'g'} because: $!\n";
    open(NEW_DISCARD_LIST, ">$tmpFile") || die "Couldn't write to scratch file $0.tmp: $!\n";
    while (<DISCARD_LIST>)
    {
        # Get the name of the card, looks like $mergeData{MNACA2} = 153
        # and the finished discard list looks like this:
        # WOO-DISCARDCA7|788113|WOO-XXX CAT ITEMS|20111003|20120328|0|0|0|20120508|0|0|
        my @record = split('\|', $_);
        # now we need the first three, and last three letters of the $record[0]
        my $cardName = substr($record[0], 0, 3).substr($record[0], 11);
        #print "Here is what merge found for a card name: ".$cardName."\n";
        # now the count if it was converted today.
        # don't update if it has a non-zero date.
        # remove the second condition if repeated updates to overwrite old finished lists.
        if (defined $mergeData{$cardName} and $record[9] == 0)
        {
            #update the date field
            $record[9] = $date;
            $record[10] = $mergeData{$cardName};
			$updated += 1;
			$totalUpdated += 1;
        }
		elsif ($record[9] > 0)
		{
			$totalUpdated += 1;
		}
        # reassemble new record:
        my $outRecord = join('|', @record);
        print NEW_DISCARD_LIST "$outRecord";
		$total += 1;
    }
    close(DISCARD_LIST);
    close(NEW_DISCARD_LIST);
    # rename the temp file to the new file finished file name and unlink it.
	print "Number updated: $updated, total updated to date: $totalUpdated of $total or ".ceil(($totalUpdated / $total) * 100)."\%.\n";
    unlink($opt{'g'});
    rename($tmpFile, $opt{'g'});
}

# keep looping for the entry in the print list by date until time runs out
# or you find it the removed report. This will fail in the rare corner case whern you have already run
# more than one remove discard report.
if ($opt{'w'})
{
    my $numLoops = $opt{'w'};
    while ($numLoops > 0)
    {
        `grep $removeReportTitle $PRINT_LIST | grep $date`;
        if ( $? == 0 )
        {
            last;
        }
        $numLoops -= sleep(5);
    }
}

open(GREP_REMOVE_REPORT,$removeDiscardCmd) || die "Failed: $!\n";
while ( <GREP_REMOVE_REPORT> )
{
    my @cols = split('\|', $_);
    # field 5 (0 indexed) contains the last run date.
    #print $cols[0].":".substr($cols[2], 0, 8)."\n";
    # if the time stamp the report ran matches the specified day (ascii).
    if (substr($cols[2], 0, 8) eq $date)
    {
        # This is the printlist entry:
        #vuct|$<remove_discard_items>|201202131040|ERROR|ADMIN|remdiscard|0||
        my $getResults = qq{grep -h $removeSuccessCode $listDir/$cols[0].log |};
        open(GREP_REMOVED, $getResults) || die "Failed: $!\n";
        while (<GREP_REMOVED>)
        {
            # to get here entry looks like: 257 <$item> $(1302)
            # now clean the record by removing the codes
            my $totalRemoved = substr($_, 0, index($_, "<") -1);
            $totalRemoved =~ s/^\s+//;
            $totalRemoved =~ s/\s+$//;
            if ($opt{v})
            {
                print "Total removed: $totalRemoved of $convertGTotal candidates.\n";
            }
            $mail .= "\n\nTotal removed $totalRemoved of $convertGTotal candidates\n";
        }
        close(GREP_REMOVED);
    }
}

close(GREP_REPORT_NAME); # Not strictly necessary.

if ($opt{m})
{
    #-- send an email to user@localhost
    my $subject = qq{"Discard Report"};
    my $addressees = qq{$opt{'m'}};
    open(MAIL, "| /usr/bin/mailx -s $subject $addressees") || die "mailx failed: $!\n";
    print MAIL "$mail\nHave a great day!";
    close(MAIL);
    #`cat report.txt | /usr/bin/mailx -s Hello anisbet\@epl.ca`;
}





