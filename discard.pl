#!/usr/bin/env perl
########################################################################
# Purpose: Makes educated guess at which DISCARD cards to convert.
# Method:  This script recommends candidate DISCARD cards based on user
#          supplied maximum discard item count; default 2000, and
#          specified by the -n option. The script will open the last_card.txt
#          file to read in the last DISCARD card successfully included
#          for candidacy, and search from there. Cards that exceed the
#          specified limit by more than 10% will be ignored and returned
#          to the next time the script is run, since each card must be
#          run only once per month.
#
#          To do this make a list of all cards for all branches and mark
#          each cards as DONE or PENDING. The PENDING can be reviewed in
#          order from the beginning or from the oldest if you reach the
#          end of the list before the end of the month.
#
#          Example: select 1500 items max to discard starting with JPL
#bash-3.00$ seluser -p"DISCARD" -y"EPLJPL" -oUBDfachb | seluserstatus -iU -oSj
#Symphony $<userstatus> $<selection> 3.4 $<started_on> $<tuesday:u>, $<april:u> 10, 2012, 10:17 AM
#Symphony $<user> $<selection> 3.4 $<started_on> $<tuesday:u>, $<april:u> 10, 2012, 10:17 AM
#$(1228)
#$(1239)
#$(1511)
#$(1496)
#$(1238)
#$(1502)
#$(1503)
#$(1246)
#$(1247)
#$(1263)
#$(1266)
#$(1262)
#  $<users:u> $(1315)$<user> $<library> $<is> EPLJPL.
#  $<users:u> $(1315)$<user> $<profile> $<is> DISCARD.
#
#                *** SQL ***
#SELECT user_key,id,title,first_name,middle_name,name,suffix,preferred_name,name_display_preference,date_created,last_activity_date,number_of_charges,number_of_holds,number_of_bills FROM users
#WHERE library IN (8) AND profile IN (10)
#ORDER BY user_key
#                *** SQL ***
#
#  520775 $<user> $(1308)
#  7 $<user> $(1309)
#Symphony $<user> $<selection> $<finished_on> $<tuesday:u>, $<april:u> 10, 2012, 10:17 AM
#JPL-DISCARDUNC|JPL-DISCARD Uncatalogued Items|20050802|20120408|0|0|0|OK|  <== Ignore UNC
#JPL-DISCARDCA1|JPL-XXX DISCARD CAT ITEMS|20090206|20120312|800|0|0|BARRED| <== Include
#JPL-DISCARDCA2|JPL-DISCARD CAT ITEMS|20090605|20120403|200|0|0|OK|         <== Include
#JPL-DISCARDCA3|JPL-DISCARD CAT ITEMS|20090702|20120407|700|0|0|OK|         <== Ignore and mark for next time
#JPL-DISCARDCA5|JPL-XXX DISCARD CAT ITEMS|20090827|20110615|500|0|0|BARRED| <== Include
#JPL-DISCARDCA6|JPL-XXX DISCARD CAT ITEMS|20090827|20110615|0|0|0|BARRED|   <== Ignore
#JPL-DISCARDCA4|JPL-XXX DISCARD CAT ITEMS|20090925|20110615|0|0|0|BARRED|   <== Ignore
#  7 $<userstatus> $(1308)
#  7 $<userstatus> $(1309)
#Symphony $<userstatus> $<selection> $<finished_on> $<tuesday:u>, $<april:u> 10, 2012, 10:17 AM
#
# Switch -m option mails results,
# -x for help and -n to specify how many discards candidates to search
# for (default: 2000). The script does not set any side effects either in
# Symphony or EPLAPP.
#
# Author:  Andrew Nisbet
# Date:    April 10, 2012
# Rev:     
#          1.5 - APIConverts incorporated.
#          1.0 - Production
#          0.0 - develop
#          July 3, 2012 - Cards available not reporting branches' barred cards
#          July 19, 2012 - Added '-fggddnn' and made consistent opt quoting.
#
########################################################################

use strict;
use warnings;
use vars qw/ %opt /;
use Getopt::Std;
# Use this for writing files to EPLAPP.
use Fcntl;          # Needed for sysopen flags O_WRONLY etc.
# See Unicorn/Bin/mailfile.pl <subject> <file> <recipients> for correct mailing procedure.

my $VERSION               = 1.5;
my $targetDicardItemCount = 2000;
# This value is used needed because not all converted items get discarded.
my $fudgeFactor           = 0.1;  # percentage of items permitted over target limit.
my $mail                  = "";   # mail content.
my %holdsCards;                   # list of cards that have holds on them
my %overLoadedCards;              # cards that exceed the convert limit set with -n
my %barCards;                     # List of cards that exceed 1000 items currently.
my %okCards;                      # List of cards whose status is OK (not BARRED).
my %barredCards;                  # List of cards whose status is BARRED.
my %billCards;                    # List of cards that have unpaid bills on them.
my %misNamedCards;                # Cards that are given DISCARD profiles by mistake.
my $today = `transdate -d+0`;
chomp($today);
my @cards;                        # Buffer of cards read from file for processing
my @sortedCards;                  # Buffer of sorted possible candidate discard cards cards.
my @finishedCards;                # List of cards to be written back to file.
my @recommendedCards;             # Todays recommended cards to convert.
my @convertCards;                 # Cards to be converted.
my $discardsFile = "finished_discards.txt"; # Name of the discards file.

#
# Message about this program and how to use it
#
sub usage()
{
    print STDERR << "EOF";

This script determines the recommended DISCARD cards to convert based on
the user specified max number of items to process - default: 2000.

usage: $0 [-xbrecq] [-n number_items] [-m email] [-t cardKey]

 -b BRAnch : request a specific branch for discards. Selecting a branch must
             be done by the 3-character prefix of the id of the card (WOO-DISCARDCA7
             would be 'WOO') and is case sensitive. Also all the cards from that
             branch will be checked and converted if -c was selected. 
 -c        : convert the recommended cards automatically.
 -e        : write the current finished discard list to MS excel format.
             default name is 'Discard[yyyymmdd].xls'.
 -m "addrs": mail output to provided address
 -n number : sets the upper limit of the number of discards to process.
 -q        : quiet mode, just print out the recommended cards. Email will still
             contain all stats.
 -r        : reset the list. Re-reads all discard cards and creates a new list.
             other flags have no effect.
 -t cardKey: convert the card with this key.
 -x        : this (help) message

example: $0 -ecq -n 1500 -m anisbet\@epl.ca -b MNA
Version: $VERSION

EOF
    exit;
}

# These functions perform the conversion if -c is used on the command line.
# param:  User Key for discard card, like 659264.
# return: integer number of cards converted or zero if none or on failure.
sub convertDiscards($)
{
	my $cardKey         = shift;
	my $status          = 0;
	# my $date3MonthsBack = `transdate -d-90`;
	my $date3MonthsBack = `transdate -d-0`; # just for testing.
	chomp($date3MonthsBack);
	print "CONVERTING: $cardKey\n";
	selectItemsToDelete( $cardKey, $date3MonthsBack );
    # #requested update of database records
	# #sets up a log of the errors from the process we want this.
    # doCommand("apiserver",
              # "-h -e$errlogdir", 
              # $TempFiles{'trans'},
              # $TempFiles{'trans_response'},
              # $TempFiles{'k'},
              # \$Directives{'status'});

      # #Capture item keys at selitem since edititem does not output keys
	  ## changes the current location to DISCARD.
      # doCommand("edititem",
                # "-8\"ADMIN|PCGUI-DISP\" -m\"DISCARD\"", 
                # $TempFiles{'keys'},
                # $TempFiles{'m'},
                # $TempFiles{'n'},
                # \$Directives{'status'});
	#use touchkeys for textedit and browse edit.
	return $status; # returns the size of the list.
}

#
#
#
sub selectItemsToDelete
{
	my ( $cardKey, $cutoffDate ) = @_;
	print "checking holds\n";
    my $holdHashRef = getHolds( $cardKey );
	# Get the list of items on this card from 90 days ago (as per EPL policy).
	#                                           selcharge -iU -c"<20120601"         -oIy | selitem -iI -oIB
    my $itemListResults = `sirsiecho $cardKey | selcharge -iU -c"<$cutoffDate" -oIy | selitem -iI -oIB 2>/dev/null`;
	my @itemKeyBarcodeList = split("\n", $itemListResults);
	my $discardItemKeysFile = qq{discard_item_keys.lst};
	my $discardItemHoldKeysFile = qq{discard_items_on_hold.lst};
	open( ITEM_KEYS, ">$discardItemKeysFile" ) or die "Error writing to '$discardItemKeysFile': $!\n";
	open( ITEM_HOLDS, ">$discardItemHoldKeysFile" ) or die "Error writing to '$discardItemHoldKeysFile': $!\n";
	foreach my $line (@itemKeyBarcodeList)
	{
		my ( $catKey, $callSeq, $copyNumber, $barCode ) = split( '\|', $line );
		if ( $holdHashRef->{ "$catKey|$callSeq|$copyNumber|" } )
		{
			print "Hold: $catKey Call sequence: $callSeq Copy number: $copyNumber\n";
			print ITEM_HOLDS "$catKey|$callSeq|$copyNumber|\n";
		}
		else
		{
			print           "$catKey|$callSeq|$copyNumber|\n";
			print ITEM_KEYS "$catKey|$callSeq|$copyNumber|\n";
		}
    }
	close( ITEM_KEYS );
	close( ITEM_HOLDS );
	# TODO get the list of bills do a 'not' on the list of keys with diff.pl!!
}

# Returns a table of all ACTIVE holds for this user key.
# param:  user key string - the user key of the discard card.
# return: hash reference of all the items on the user's card that have active holds. 
#         May be empty but not undefined.
sub getHolds($)
{
	my $cardKey = shift;
	my $holdResults =   `sirsiecho $cardKey | selhold -iU            -oI 2>/dev/null`; # for testing.
	# my $holdResults = `sirsiecho $cardKey | selhold -iU -j"ACTIVE" -oI 2>/dev/null`;
	my @holdItemList = split("\n", $holdResults);
	my $hashRef = {};
	foreach my $itemKey ( @holdItemList )
	{
		chomp( $itemKey );
		$hashRef->{ $itemKey } = 1;
	}
	return $hashRef;
}

sub recordDiscardTransaction
{
	my ( $catKey, $callSeq, $copyNumber ) = @_;
	my $date;
	chomp($date = `transdate -d-0 -h`);
	my $station = "PCGUI-DISP";
	my $uacs    = "ADMIN";
	print "Cat key: $catKey     Call sequence: $callSeq      Copy number: $copyNumber\n";
	# if (!open(INFILE,$TempFiles{'items'}))
	# {
	# PrintMessage("\nCannot open $TempFiles{'items'}\n","$TempFiles{'z'}");
	# }
	# elsif (!open(OUTFILE,">>$TempFiles{'trans'}"))
	# {
	# close INFILE;
	# PrintMessage("\nCannot open output file($TempFiles{'trans'})\n","$TempFiles{'z'}");
	# }
	# else
	# {
	# while (<INFILE>)
	  # {
	  # chomp;
	  # $data = $_;
	  # $itemid = (split(/\|/))[0];
	  # $library = (split(/\|/))[1]; 
	  # printf OUTFILE ("D%s%s ^S01EVFF%s^FE%s^NQ%s^OM^^O\n",$date,$station,$uacs,$library,$itemid);
	  # }
	# #close file handles
	# close INFILE;
	# close OUTFILE;
	# }
}


# Kicks off the setting of various switches.
# param:
# return:
sub init()
{
    my $opt_string = 'rm:n:xeb:cqt:';
    getopts( "$opt_string", \%opt ) or usage();
    usage() if ($opt{'x'});                            # User needs help
    $targetDicardItemCount = $opt{'n'} if ($opt{'n'}); # User set n
    if ($opt{'r'})
    {
        my $apiCmd = qq{seluser -p"DISCARD" -oUBDfachb | seluserstatus -iU -oUSj | selascii -iR -oF2F1F3F4F5F6F7F8F9};
        my $results = `$apiCmd`;
        @cards = split("\n", $results);
        @sortedCards = sort(@cards);
        # This is required to write files to the EPLAPP FS:
        sysopen(OUT, "finished_discards.txt", O_WRONLY | O_TRUNC | O_CREAT) ||
            die "Couldn't create list because of failure: $!\n";
        foreach (@sortedCards)
        {
            if ($_ =~ m/DISCARDUNC/ or $_ =~ m/EPL-WEED/) # only keep UNC discard entries.
            {
                next;
            }
            if ($_ =~ m/DISCARD-BTGFTG/ or $_ =~ m/WITHDRAW-THIS-ITEM/ or $_ =~ m/ILS-DISCARD/)
            {
                next;
            }
            print OUT $_."00000000|0|\n";
        }
        close(OUT);
        print "created new discard file in current directory.\n";
        exit(0);
    }
	elsif ( $opt{'t'} )
	{
		my $result = convertDiscards( $opt{'t'} );
		print "$result items discarded from card: $opt{'t'}\n" if ( $result );
		exit( 1 );
	}
    else
    {
        # This is required to write files to the EPLAPP FS:
        sysopen(IN, "finished_discards.txt", O_RDONLY) ||
            die "Couldn't open finished_discards.txt because: $!\n";
        while (<IN>)
        {
            push(@cards, $_);
        }
        close(IN);
        @sortedCards = sort(@cards);
        print "read list successfully\n";
    }
}

################
# Main entry
init();
# set the allowable over-limit value. To adjust change fudgefactor above.
$targetDicardItemCount = $targetDicardItemCount * $fudgeFactor + $targetDicardItemCount;
print "discard item goal: $targetDicardItemCount\n";
my $runningTotal   = 0;
my $convertedTotal = 0;
foreach (@sortedCards)
{
    chomp($_);
    #print "processing: $_\n";
    # split the fields so we can capture the reporting details:
    # Barcode       | title of card (HC)  | D_init  | Last use| # | Converted/Removed.
    # IDY-DISCARDCA6|IDY-DISCARD CAT ITEMS|6/11/2009|3/19/2012|618|147
    # but we get this from the Sirsi query:
    # LHL-DISCARDCA8|LHL-DISCARD CAT ITEMS|20110820|20120403|445|0|0|OK|
    # and this from the finished_discards.txt file:
	# WOO-DISCARDCA6|671191|XXXWOO-DISCARD CAT ITEMS|20100313|20120507|1646|0|0|OK|00000000|0|
    my ($id, $userKey, $description, $dateCreated, $dateUsed, $itemCount, $holds, $bills, $status, $dateConverted, $converted) = split('\|', $_);
    # let's do some reporting on the health of the cards:
    if ($id =~ m/^\d{5,}/)
    {
        $misNamedCards{$id} = "$description|$dateCreated|$dateUsed|$itemCount|$holds|$bills|$status|";
        next; # don't remove items from a mis-named card.
    }
    if ($holds > 0)
    {
        $holdsCards{$id} = $holds;
    }
    if ($bills > 0)
    {
        $billCards{$id} = $bills;
    }
	my $branchCode = substr($id, 0, 3);
    if ($status eq "OK")
    {
        $okCards{$branchCode} += 1;
    }
	else
	{
		$barredCards{$branchCode} += 1;
	}
    if ($itemCount > $targetDicardItemCount)
    {
        $overLoadedCards{$id} = "$description|$dateCreated|$dateUsed|$itemCount|$holds|$bills|$status Item Count = $itemCount";
    }
	# Test if we are looking for a specific branch and if this card doesn't match skip it.
    if ( $opt{'b'} and $opt{'b'} !~ m/($branchCode)/)
	{
		print "[Branch mode] skipping '$description'\n";
	}
	elsif ( $itemCount <= $targetDicardItemCount and $dateConverted == 0 ) # else check if it matches the day's quotas.
    {
		#print "my branch code is $branchCode and $opt{'b'} was selected\n";
        if ($itemCount + $runningTotal <= $targetDicardItemCount)
        {
            # update the running total
            $runningTotal += $itemCount;
			# if convert not selected we will get the same recommendations tomorrow.
			if ($opt{'c'})
			{
				my $converted = convertDiscards( $userKey );
				if ($converted) # if conversion successful.
				{
					$dateConverted  = $today;
					$convertedTotal += $converted; # change to the actual number converted items.
				}
			}
			# you always get a list of recommendations.
            push(@recommendedCards, $id);
        }
    }
	# reconstitute the record for writing to file
    my $record = "$id|$userKey|$description|$dateCreated|$dateUsed|$itemCount|$holds|$bills|$status|$dateConverted|$converted|";
    #print " processed: $record\n";
    # rebuild the entry for writing to file.
    push(@finishedCards, $record);
}

# Write the file out again.
sysopen(OUT, "finished_discards.txt", O_WRONLY | O_TRUNC | O_CREAT) ||
    die "Couldn't create list because of failure: $!\n";
foreach (@finishedCards)
{
    print OUT $_."\n";
    #print $_."\n";
}
close(OUT);
# finish reporting.

$mail .= "Discard item count: $runningTotal\nDiscard converted: $convertedTotal (#cards)\n";
$mail .= reportStatus("The following cards have holds:", %holdsCards);
$mail .= reportStatus("The following cards have bills:", %billCards);
$mail .= reportStatus("The following cards are too big for quota:", %overLoadedCards);
$mail .= reportStatus("The following cards have accidentally been given profile of DISCARD:", %misNamedCards);
$mail .= reportStatus("Total available DISCARD cards:", %okCards);
$mail .= reportStatus("Total barred DISCARD cards:", %barredCards);

if (!$opt{'q'})
{
	print "$mail\n";
}
print "Convert the following cards:\n=== snip ===\n";
foreach (@recommendedCards)
{
    print "$_\n";
	$mail .= "$_\n";
}
print "=== snip ===\n";


################
# Mail the results to the recipients.
if ($opt{'m'})
{
    #-- send an email to user@localhost
    my $subject = qq{"Discard"};
    my $addressees = qq{$opt{'m'}};
    open(MAIL, "| /usr/bin/mailx -s $subject $addressees") || die "mailx failed: $!\n";
    print MAIL "$mail\nHave a great day!";
    close(MAIL);
}

# Option 'e' converts the pipe-delimited data into an excel file. There is a requirement
# for excel.pl to be executable in custombin.
# param: none
# return: none
if ($opt{'e'})
{
    sysopen(CARDS, $discardsFile, O_RDONLY) ||
        die "Couldn't read '$discardsFile' because of failure: $!\n";
    open(EXCEL, "| excel.pl -t 'Patron ID|Name|Created|L.A.D|No. of Charges|No. of Converts|' -o Discards$today.xls -fggddnn")
        || die "excel.pl failed: $!\n";
    while (<CARDS>)
    {
        my ($id, $userKey, $description, $dateCreated, $dateUsed, $itemCount, $holds, $bills, $status, $dateConverted, $converted) = split('\|', $_);
        print EXCEL "$id|$description|$dateCreated|$dateUsed|$itemCount|$converted|\n";
    }
    close(EXCEL);
    close(CARDS);
}


# Prints a report of the contents of the various collections of cards.
# param: report title
# param: items to be reported
# return: string containing report results.
sub reportStatus
{
    my ($reportMessage, %items) = @_;
	if (keys(%items) == 0)
	{
		return "";
	}
    my $msg = $reportMessage."\n";
    while (my ($key, $value) = each(%items))
    {
        if ($value) # required if there is an empty value.
        {
            $msg .= $key." => ".$value."\n";
        }
    }
    $msg .= "\n";
    return $msg;
}

