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
my $DISC                  = 0b00000001;
my $LCPY                  = 0b00000010;
my $BILL                  = 0b00000100;
my $ORDR                  = 0b00001000;
my $SCTL                  = 0b00010000;
my $ACCT                  = 0b00100000;
my $HTIT                  = 0b01000000;
my $HCPY                  = 0b10000000;
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
my $tmpFileName  = qq{tmp_a};
chomp( my $tmpDir= `getpathname tmp` );

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
             would be 'WOO') and is uc/lc sensitive. Also all the cards from that
             branch will be checked and converted if -c was selected. 
 -c        : convert the recommended cards automatically.
 -d        : turn on debugging output.
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

# Reads the contents of a file into a hash reference.
# param:  file name string - path of file to write to.
# return: hash reference - table data.
sub readTable($)
{
	my ( $fileName ) = shift;
	my $table = {};
	open TABLE, "<$fileName" or die "Serialization error reading '$fileName' $!\n";
	while (<TABLE>)
	{
		chomp;
		$table->{$_} = 1;
	}
	close TABLE;
	return $table;
}

# Writes the contents of a hash reference to file. Values are not stored.
# param:  file name string - path of file to write to.
# param:  table hash reference - data to write to file (keys only).
# return: 
sub writeTable($$)
{
	my $fileName = shift;
	my $table    = shift;
	open TABLE, ">$fileName" or die "Serialization error writing '$fileName' $!\n";
	for my $key (keys %$table)
	{
		print TABLE "$key\n";
	}
	close TABLE;
	return $table;
}


# Moves all items to location DISCARD.
# param:  hash reference of discarded cat keys.
# return: count of items moved.
sub moveItemsToDISCARD( $ )
{
	my ( $discardHashRef ) = shift;
	# first job: create a file of the cat keys we have left on the hash ref.
	my $barCodeFile = "$tmpDir/T_DISCARD_BARC.lst";
	my $requestFile = "DISCARD_transaction_request.cmd";
	my $responseFile= "DISCARD_transaction_reponse.log";
	writeTable( $barCodeFile, $discardHashRef );
	# second job: get the barcodes.
	my $barCodes = `cat $barCodeFile | selitem -iK -oBm 2>/dev/null`;
	unlink( $barCodeFile ); # clean up the temp file.
	my @barCodesLocations = split( '\n', $barCodes );
	# third job: create the API command for discharge the item off the discard card.
	# we first discharge the item then right after we change its location to DISCARD.
	open( API_SERVER_TRANSACTION_FILE, ">$requestFile" ) or die "Couldn't write to '$requestFile' $!\n";
	my $transactionSequenceNumber = 0;
	chomp( my $dateTime = `date +%Y%m%d%H%M%S` );
	foreach  ( @barCodesLocations )
	{
		my ( $barCode, $currentLocation ) = split( '\|', $_ );
		# unique-per-second transcation numbering for logging and idempotent transaction atomicity within database.
		$transactionSequenceNumber = 1 if ( $transactionSequenceNumber++ >= 99 );
		# create server transaction for discharge
		print API_SERVER_TRANSACTION_FILE getDischargeTransaction( $barCode, $transactionSequenceNumber, $dateTime );
		$transactionSequenceNumber = 1 if ( $transactionSequenceNumber++ >= 99 );
		# create server transaction for change location to Discard.
		print API_SERVER_TRANSACTION_FILE getChangeLocationTransaction( $barCode, $transactionSequenceNumber, $currentLocation );
	}
	close( API_SERVER_TRANSACTION_FILE );
	# fourth job: run the apiserver with the commands to convert the discards.
	# `apiserver -h <$requestFile >$responseFile`;
}

# Creates a change location transaction command.
# param:  barCode string - bar code for the item being moved.
# param:  sequenceNumber string - sequence number between 1-99.
# param:  currentLocation string - current location of the item.
# return: transaction as a string.
sub getChangeLocationTransaction( $$$ )
{
	my ( $barCode )        = shift;
	my ( $sequenceNumber ) = shift;
	my ( $currentlocation )= shift;
	my $transactionRequestLine    = '^S';
	$transactionRequestLine = '^S';
	$transactionRequestLine .= $sequenceNumber = '0' x ( 2 - length( $sequenceNumber ) ) . $sequenceNumber;
	$transactionRequestLine .= 'IV'; #Edit Item Part B command code
	$transactionRequestLine .= 'FF'; #station login user access
	$transactionRequestLine .= 'ADMIN';
	$transactionRequestLine .= '^';
	$transactionRequestLine .= 'FE'; #station library
	$transactionRequestLine .= 'EPLMNA';
	$transactionRequestLine .= '^';
	$transactionRequestLine .= 'OM'; #master override
	$transactionRequestLine .= '^';
	$transactionRequestLine .= 'NQ'; #Item ID
	$transactionRequestLine .= $barCode;
	$transactionRequestLine .= '^';
	$transactionRequestLine .= 'IL'; #Current Location
	$transactionRequestLine .= $currentlocation;
	$transactionRequestLine .= '^';
	$transactionRequestLine .= '^';
	$transactionRequestLine .= 'O';
	return "$transactionRequestLine\n";
}

# Creates a discharge transaction.
# param:  barCode string - bar code for an item.
# param:  sequenceNumber string - sequence number between 1-99.
# param:  date string - date time stamp in log format.
# return: string well formed apiserver transaction string.
sub getDischargeTransaction( $$$ )
{
	my ( $barCode )        = shift;
	my ( $sequenceNumber ) = shift;
	my ( $dischargeDate )  = shift;
	# looks like: 
	# E201209281019291224R ^S72EVFWSORTLHL^FEEPLLHL^FFSORTATION^FcNONE^dC6^NQ31221094990483^CO9/28/2012,10:19^^O
	# Here is one from the remove report:
	# E201209280833001220R ^S53EVFFADMIN^FEEPLMLW^NQ31221095677535  ^OM^DB20120928083300^^O00064
	# Chris's code:
	#Example: Request Line (discharge) from a Log File:
	#E200808010805220634R ^S86EVFFCIRC^FEEPLJPL^FcNONE^FWJPLCIRC^NQ31221082898953^CO08/01/2008^Fv20000000^^O
	#Below is same line but using logprint and translate commands:
	#8/1/2008,08:05:22 Station: 0634 Request: Sequence #: 86 Command: Discharge Item station login user access:CIRC
	#station library:EPLJPL  station login clearance:NONE  station user's user ID:JPLCIRC  item ID:31221082898953
	#date of discharge:08/01/2008  Max length of transaction response:20000000
	#-----------------------------------------------------------
	my $transactionRequestLine = '^S';
	$transactionRequestLine .= $sequenceNumber = '0' x ( 2 - length( $sequenceNumber ) ) . $sequenceNumber;
	$transactionRequestLine .= 'EV'; #Discharge Item command code
	$transactionRequestLine .= 'FF'; #station login user access
	$transactionRequestLine .= 'ADMIN';
	$transactionRequestLine .= '^';
	$transactionRequestLine .= 'FE'; #station library
	$transactionRequestLine .= 'EPLMNA';
	$transactionRequestLine .= '^';
	$transactionRequestLine .= 'FcNONE';
	$transactionRequestLine .= '^';
	$transactionRequestLine .= 'FW'; #station user's user ID
	$transactionRequestLine .= 'ADMIN';
	$transactionRequestLine .= '^';
	$transactionRequestLine .= 'NQ'; #Item ID
	$transactionRequestLine .= $barCode;
	$transactionRequestLine .= '^';
	$transactionRequestLine .= 'OM'; #master override
	$transactionRequestLine .= '^';
	$transactionRequestLine .= 'DB'; #Date of Discharge
	$transactionRequestLine .= $dischargeDate; # 20120928135216
	$transactionRequestLine .= '^';
	$transactionRequestLine .= 'Fv'; #Max length of transaction response
	$transactionRequestLine .= '20000000';
	$transactionRequestLine .= '^';
	$transactionRequestLine .= '^';
	$transactionRequestLine .= 'O';
	return "$transactionRequestLine\n";
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
	my $discardHashRef = selectItemsToDelete( $cardKey, $date3MonthsBack );
	# policy order is important since remove last copy, then remove last copy + holds
	# is not the same as remove last copy + holdsf then remove last copy.
	my @EPLPreservePolicies = ( ( $HTIT | $LCPY ), $LCPY, $BILL, $ORDR, $SCTL, $HCPY );
	my $totalDiscards = reportAppliedPolicies( $discardHashRef, @EPLPreservePolicies );
	print "Total discards to process: $totalDiscards items.\n";
	# move all discarded items to location DISCARD.
	my $moveCount = moveItemsToDISCARD( $discardHashRef );
    
	return $status; # returns the size of the list.
}

# Produces a hash of item keys for DISCARD conversion marking each item with the code 
# for exclusion. If the code is zero the item is cleared for conversion and removal.
# param:  cardKey string - key of the discard card.
# param:  cutoffDate string - date 
# return: hash reference of item keys -> exclude code where:
sub selectItemsToDelete
{
	my ( $cardKey, $cutoffDate ) = @_;
	print "checking holds\n";
	my $discardHashRef = getDiscardedItemsFromCard( $cardKey, $cutoffDate );
	open( TMP, ">$tmpFileName" ) or die "Error writing to tmp file: $!\n";
	for my $key ( keys %$discardHashRef )
	{
        print TMP "$key\n";
    }
	close( TMP );
	# now set the bits for each of the DISCARD business rules.
    markItems( "LAST_COPY", $discardHashRef );
	markItems( "WITH_BILLS", $discardHashRef );
	markItems( "WITH_ORDERS", $discardHashRef );
	markItems( "ARE_ACCOUNTABLE", $discardHashRef );
	markItems( "UNDER_SERIAL_CONTROL", $discardHashRef );
	markItems( "WITH_TITLE_HOLDS", $discardHashRef );
    markItems( "WITH_COPY_HOLDS", $discardHashRef );
	return $discardHashRef;
}

# Applys library discard policies to the discarded items and reports the
# items that fail to match discardable discard material tests.
# param:  policies string - values to filter out non-discardable items.
# param:  item key hash reference - values hold bit map test code results.
#         See markItems() for more details.
sub reportAppliedPolicies
{
	my ( $discardHashRef, @policies ) = @_;
	if ( $opt{'d'} )
	{
		my ( $key, $value );
		format FORM = 
@<<<<<<<<<<<<< @##
$key,   $value
.
		$~ = "FORM";
		while ( ($key, $value) = each( %$discardHashRef ) )
		{
			write;
		}
		$~ = "STDOUT";
	}
	
	foreach my $policy ( @policies )
	{
		print "reporting policy: ";
		if    ( $policy == $LCPY )            { open( OUT, ">DISCARD_LCPY.lst" ) or die "Error: $!\n"; print "last copy\n"; }
		elsif ( $policy == $BILL )            { open( OUT, ">DISCARD_BILL.lst" ) or die "Error: $!\n"; print "bills\n"; }
		elsif ( $policy == $ORDR )            { open( OUT, ">DISCARD_ORDR.lst" ) or die "Error: $!\n"; print "items on order\n"; }
		elsif ( $policy == $SCTL )            { open( OUT, ">DISCARD_SCTL.lst" ) or die "Error: $!\n"; print "serials\n"; }
		elsif ( $policy == ( $HTIT | $LCPY ) ){ open( OUT, ">DISCARD_LCHT.lst" ) or die "Error: $!\n"; print "last copy with holds\n"; }
		elsif ( $policy == $HCPY )            { open( OUT, ">DISCARD_HCPY.lst" ) or die "Error: $!\n"; print "copy holds\n"; }
		else  { print "unknown '$policy'\n"; }
		while ( my ($key, $value) = each( %$discardHashRef ) )
		{
			if ( ( $policy & $value ) == $policy )
			{
				print OUT "$key\n";
				# remove the item from the list of discards since the policy matches a 'keep' policy.
				# -------------------------
				# revisit this. Chris thinks we can move all items to DISCARD since the remove report will 
				# also filter before it does its remove. The up-shot is that all the items will be moved off
				# the discard card and locatable by DISCARD location.
				# delete( $discardHashRef->{ $key } );
			}
		}
		close( OUT );
	}
	return scalar( keys( %$discardHashRef ) );
}


# Marks items that are not to be discarded. Any value that is greater than 0 will be preserved.
# Values are bit ordered so the reason of the disqualification can be tested.
# 1  = good to DISCARD
# 2  = last copy
# 4  = item has bills
# 8  = item has orders pending
# 16 = item is under serial control
# 32 = item is accountable
# 64 = item has title level hold
# 128= item has copy level hold
# param:  keyWord string - The name of the disqualification check.
# param:  hash reference of items on the discard card.
# return: 
# side effect: modifies the value of hash keys by summing applicable disqualification codes.
#              and 0 if there is no pediment to the item being discarded.
sub markItems
{
	my ( $keyWord, $discardHashRef ) = @_;
	my $results  = "";
	# while this code looks amature-ish it is clearer and has no negative spacial or temporal impact on the script.
	if    ( $keyWord eq "LAST_COPY" )           { print "checking last copy "; $results = `cat $tmpFileName | selcallnum    -iN -c"<2"     -oNS 2>/dev/null`; }
	elsif ( $keyWord eq "WITH_BILLS" )          { print "checking bills ";     $results = `cat $tmpFileName | selbill       -iI -b">0.00"  -oI  2>/dev/null`; }
	elsif ( $keyWord eq "WITH_ORDERS" )         { print "checking orders ";    $results = `cat $tmpFileName | selorderlin   -iC            -oCS 2>/dev/null`; }
	elsif ( $keyWord eq "UNDER_SERIAL_CONTROL" ){ print "checking serials ";   $results = `cat $tmpFileName | selserctl     -iC            -oCS 2>/dev/null`; }
	elsif ( $keyWord eq "WITH_TITLE_HOLDS" )    { print "checking holds ";     $results = `cat $tmpFileName | selhold -t"T" -iC -j"ACTIVE" -oCS 2>/dev/null`; }
	elsif ( $keyWord eq "WITH_COPY_HOLDS" )     { print "checking holds ";     $results = `cat $tmpFileName | selhold -t"C" -iC -j"ACTIVE" -oCS 2>/dev/null`; }
	else  { print "skipping: '$keyWord'\n" if ( $opt{'d'} ); return; }
	my @itemList  = split( "\n", $results );
	print "completed, ".scalar( @itemList )." related hits\n";
	foreach my $itemKey ( @itemList )
	{
		chomp( $itemKey );
		# some commands only take a cat key and produce many results with cat keys that don't match. Only update the
		# values of cat keys that match.
		next if ( not $discardHashRef->{ $itemKey } );
		if    ( $keyWord eq "LAST_COPY" )           { $discardHashRef->{ $itemKey } |= $LCPY; }
		elsif ( $keyWord eq "WITH_BILLS" )          { $discardHashRef->{ $itemKey } |= $BILL; }
		elsif ( $keyWord eq "WITH_ORDERS" )         { $discardHashRef->{ $itemKey } |= $ORDR; }
		elsif ( $keyWord eq "UNDER_SERIAL_CONTROL" ){ $discardHashRef->{ $itemKey } |= $SCTL; }
		elsif ( $keyWord eq "WITH_TITLE_HOLDS" )    { $discardHashRef->{ $itemKey } |= $HTIT; }
		elsif ( $keyWord eq "WITH_COPY_HOLDS" )     { $discardHashRef->{ $itemKey } |= $HCPY; }
		else  { ; }
	}
}

# Gets all of the items checked out to the argument discard card.
# param:  cardKey string - User key for the discard card.
# return: hash reference keys: item key, values: 0.
sub getDiscardedItemsFromCard
{
	my ( $cardKey, $cutoffDate ) = @_;
	# Get the list of items on this card from 90 days ago (as per EPL policy).
	#                                           selcharge -iU -c"<20120601"       -oIy | selitem -iI -oIB
    my $itemListResults    = `sirsiecho $cardKey | selcharge -iU -c"<$cutoffDate" -oIy | selitem -iI -oIB 2>/dev/null`;
	my @itemKeyBarcodeList = split("\n", $itemListResults);
	my $itemKeyHashRef     = {};
	foreach my $line ( @itemKeyBarcodeList )
	{
		my ( $catKey, $callSeq, $copyNumber, $barCode ) = split( '\|', $line );
		$itemKeyHashRef->{ "$catKey|$callSeq|$copyNumber|" } = $DISC;
    }
	return $itemKeyHashRef;
}

# Kicks off the setting of various switches.
# param:
# return:
sub init()
{
    my $opt_string = 'b:cdem:n:qrt:x';
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

