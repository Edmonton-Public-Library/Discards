#!/usr/bin/env perl
########################################################################
# Purpose: Makes educated guess at which DISCARD cards to convert.
# Method:  
# This script recommends candidate DISCARD cards based on user
# supplied maximum discard item count; default 2000, and
# changed with the -n option. Cards that exceed the 
# specified limit by more than 10% will be ignored and can
# be reported with -Q (think quota).
#
# Running the script with no switches will just output the 
# convert target total and exit. Use -c to convert the items on 
# recommended cards. While performing the conversion, cards are
# checked for Bills, copy level holds and other policies 
# which are recorded to predefined files. For example: if
# and item has is a last copy and has a hold on it, its
# item key is stored in the DISCARD_LCHC.lst file. There
# is a .lst file for all the policies and they are maintained
# by the script as it runs - that is - in our example if 
# the item key already existed in the file, nothing further
# happens. If, however, the key doesn't exist it will be added.
#
# Every time a DISCARD card is converted, the items are all checked for
# the following policies: 
# last copy, bills, on order, serial controlled items, title level
# holds and copy level holds. 
# Every time an item matches a policy a bit is set for that
# policy. Once all the policies are applied, each policy list
# is updated with that item, where appropriate.
#
# Additionally cards are checked for quotas, misnaming, status
# and the list of recommended cards. You can always run these
# checks safely - the recommend flag is intended for use 
# when discards are performed manually.
#
# Manual DISCARD instructions:
# 1) Run the discard script without the '-c' switch, but include 
# the '-R' switch. This will report cards that are recommended
# for conversion. 
# 2) In Workflows select schedule new report 
# wizard and follow the discard instructions in ITS Docs.
# 3) Run 'remove DISCARD items' from the schedule new report 
# wizard.
# 4) Use discard_report.pl -g finished_discards.txt -v 
# to update the finished discard list.
# 5) Rinse and repeat for the next card.
#
# Instructions to run from command line:
# 1) run discard.pl -c
# 2) Run 'remove DISCARD items' from the schedule new report 
# wizard.
#
# Instructions for Cronned job:
# Schedule with cron daily, schedule remove report daily then
# 1) no action required.
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
use POSIX qw/ceil/;

# See Unicorn/Bin/mailfile.pl <subject> <file> <recipients> for correct mailing procedure.
# Environment setup required by cron to run script because its daemon runs
# without assuming any environment settings and we need to use sirsi's.
###############################################
# *** Edit these to suit your environment *** #
$ENV{'PATH'} = ":/s/sirsi/Unicorn/Bincustom:/s/sirsi/Unicorn/Bin:/s/sirsi/Unicorn/Search/Bin:/usr/bin";
$ENV{'UPATH'} = "/s/sirsi/Unicorn/Config/upath";
###############################################
my $VERSION               = 1.5;
my $ALL_CARDS_CONVERTED   = 2;
my $DISC                  = 0b00000001;
my $LCPY                  = 0b00000010;
my $BILL                  = 0b00000100;
my $ORDR                  = 0b00001000;
my $SCTL                  = 0b00010000;
my $ACCT                  = 0b00100000;
my $HTIT                  = 0b01000000;
my $HCPY                  = 0b10000000;
# api calls
my $apiReportDISCARDStatus = qq{seluser -p"DISCARD" -oUBDfachb | seluserstatus -iU -oUSj | selascii -iR -oF2F1F3F4F5F6F7F8F9};
# policy order is important since remove last copy, then remove last copy + holds
# is not the same as remove last copy + holdsf then remove last copy.
my @EPLPreservePolicies = ( ( $HTIT | $LCPY ), $LCPY, $BILL, $ORDR, $SCTL, $HCPY );
chomp( my $discardRetentionPeriod  = `transdate -d-90` );
#chomp( my $discardRetentionPeriod = `transdate -d-0` ); # just for testing.
my $targetDicardItemCount = 2000;
# This value is used needed because not all converted items get discarded.
my $fudgeFactor           = 0.1;  # percentage of items permitted over target limit.
my $C_OK                  = 0b000001;
my $C_OVERLOADED          = 0b000010;
my $C_BARRED              = 0b000100;
my $C_MISNAMED            = 0b001000;
my $C_RECOMMEND           = 0b010000; # recommended cards get selected for conversion.
my $C_CONVERTED           = 0b100000;
chomp( my $today          = `transdate -d+0` );
chomp( my $tmpDir         = `getpathname tmp` );
my $pwdDir                = qq{/s/sirsi/Unicorn/EPLwork/cronjobscripts/Discards};
my $tmpFileName           = qq{$tmpDir/tmp_a};
my $discardsFile          = qq{$pwdDir/finished_discards.txt}; # Name of the discards file.
my $requestFile           = qq{$pwdDir/DISCARD_TXRQ.cmd};
my $responseFile          = qq{$pwdDir/DISCARD_TXRS.log};
my $excelFile             = qq{$pwdDir/Discards$today.xls};

#
# Message about this program and how to use it
#
sub usage()
{
    print STDERR << "EOF";

This script determines the recommended DISCARD cards to convert based on
the user specified max number of items to process - default: 2000.

usage: $0 [-bBceMorRQx] [-n number_items] [-m email] [-t cardKey]

 -B        : reports cards that have BARRED status.
 -b BRAnch : request a specific branch for discards. Selecting a branch must
             be done by the 3-character prefix of the id of the card (WOO-DISCARDCA7
             would be 'WOO') and is uc/lc sensitive. Also all the cards from that
             branch will be checked and converted if -c was selected. 
 -c        : convert the recommended cards automatically.
 -d        : turn on debugging output.
 -e        : write the current finished discard list to MS excel format.
             default name is 'Discard[yyyymmdd].xls'.
 -m "addrs": mail output to provided address(es).
 -M        : reports cards that are incorrectly identified with DISCARD profile.
 -n number : sets the upper limit of the number of discards to process. This is a 
             two step process. The number on the card is used to get into the ballpark
             of total to convert, but an exact number depends on the convert process
             and whether there are bills, holds etc. attached to any of the items.
 -o        : report all items from the DISCARD location. Creates lists of those item's
             retension reason.
 -Q        : reports cards that are over-quota.
 -r        : reset the list. Re-reads all discard cards and creates a new list.
             other flags have no effect.
 -R        : reports cards that are recommended for conversion.
 -t cardKey: convert the card with this key.
 -x        : this (help) message

example: $0 -ecq -n 1500 -m anisbet\@epl.ca -b MNA
Version: $VERSION

EOF
    exit;
}

# Writes the finished Discard card list to file.
# The format of the file is one card per line in the format:
# WOO-DISCARDCA6|671191|XXXWOO-DISCARD CAT ITEMS|20100313|20120507|1646|0|0|OK|00000000|0|
# param:  List of card details to write to file.
# return: 
# side effect: writes the $discardFile to the current directory.
sub writeDiscardCardList
{
	my ( @cards ) = @_;
	open( CARDS, ">$discardsFile" ) or die "Couldn't read '$discardsFile' because $!\n";
	foreach ( @cards )
	{
		print CARDS "$_\n";
	}
	close( CARDS );
	print "created '$discardsFile'.\n" if ( $opt{'d'} );
}

# Reads the list of discard cards.
# param:  
# return: List of cards in format: WOO-DISCARDCA6|671191|XXXWOO-DISCARD CAT ITEMS|20100313|20120507|1646|0|0|OK|00000000|0|
sub readDiscardCardList
{
	my @cards = ();
	open( CARDS, "<$discardsFile" ) or die "Couldn't read '$discardsFile' because $!. Did you forget to create one with '-r'?\n";
	while ( <CARDS> )
	{
		push( @cards, $_ );
	}
	close( CARDS );
	chomp( @cards );
	print "read '$discardsFile'\n" if ( $opt{'d'} );
	return sort( @cards );
}

# This function is intended to serialize a given table.
# param:  table name string path of table.
# param:  data hash reference of data to write.
# return: 
sub writeTable( $$ )
{
	my ( $tableName, $hashRef ) = @_;
	open( TABLE, ">$tableName" ) or die "Couldn't write to '$tableName' $!\n";
	for my $key ( keys %$hashRef )
	{
		print TABLE "$key\n";
	}
	close( TABLE );
	print "serialized '$tableName'.\n" if ( $opt{'d'} );
}

# This function is intended to serialize a given table.
# param:  table name string path of table.
# param:  data hash reference of data to write.
# return: 
sub readTable( $$ )
{
	my ( $tableName, $hashRef ) = @_;
	return if ( not -s $tableName );
	open( TABLE, "<$tableName" ) or die "Couldn't read from '$tableName' $!\n";
	while ( <TABLE> )
	{
		chomp( $_ );
		$hashRef->{ $_ } = 1;
	}
	close( TABLE );
	print "deserialized '$tableName'.\n" if ( $opt{'d'} );
}

# Creates entries that will move all items to location DISCARD via 
# a API server transaction file.
# param:  hash reference of discarded cat keys.
# return: count of items moved.
sub createAPIServerTransactions( $ )
{
	my ( $discardHashRef ) = shift;
	# first job: create a file of the cat keys we have left on the hash ref.
	my $barCodeFile = "$tmpDir/T_DISCARD_BARC.lst";
	writeTable( $barCodeFile, $discardHashRef );
	# second job: get the barcodes.
	my $barCodes = `cat $barCodeFile | selitem -iK -oBm 2>/dev/null`;
	unlink( $barCodeFile ); # clean up the temp file.
	my @barCodesLocations = split( '\n', $barCodes );
	# third job: create the API command for discharge the item off the discard card.
	# we first discharge the item then right after we change its location to DISCARD.
	open( API_SERVER_TRANSACTION_FILE, ">>$requestFile" ) or die "Couldn't write to '$requestFile' $!\n";
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
	# The file is now ready for the apiserver command to be run against it.
	return scalar( @barCodesLocations );
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

# Creates a discharge transaction string for a single item.
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

# This function performs all the high level activities of converting items
# to discard, with the exception of actually running the apiserver. This is 
# because we want to append all server transactions to one file an then run 
# it after all cards for the day have been converted. The apiserver is much
# more efficient if we run the apiserver against all.
# param:  User Key for discard card, like 659264.
# return: integer number of cards converted or zero if none or on failure.
sub selectReportPrepareTransactions( $$ )
{
	my $cardKey        = shift;
	my $cardName       = shift;
	print "CONVERTING: $cardKey - $cardName\n";
	# return 555; # Use this to test return bogus results for reports and finished discard file.
	my $discardHashRef = selectItemsToDelete( $cardKey, $discardRetentionPeriod );
	my $totalDiscards  = reportAppliedPolicies( $discardHashRef, @EPLPreservePolicies );
	print "Total discards to process: $totalDiscards items.\n";
	# move all discarded items to location DISCARD.
	my $convertCount   = createAPIServerTransactions( $discardHashRef );
	return $convertCount; # returns the number of items converted.
}

# Produces a hash of item keys for DISCARD conversion marking each item with the code 
# for exclusion. If the code is zero the item is cleared for conversion and removal.
# param:  cardKey string - key of the discard card.
# param:  cutoffDate string - date 
# return: hash reference of item keys -> exclude code where:
sub selectItemsToDelete
{
	my ( $cardKey, $cutoffDate ) = @_;
	my $discardHashRef = getDiscardedItemsFromCard( $cardKey, $cutoffDate );
	open( TMP, ">>$tmpFileName" ) or die "Error writing to '$tmpFileName': $!\n";
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
# require: $tmpFileName which is a list of item keys separated by new lines.
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
		my $prevCards = {};
		print "reporting policy: ";
		if    ( $policy == $LCPY )            { readTable( "$pwdDir/DISCARD_LCPY.lst", $prevCards ); print "last copy\n"; }
		elsif ( $policy == $BILL )            { readTable( "$pwdDir/DISCARD_BILL.lst", $prevCards ); print "bills\n"; }
		elsif ( $policy == $ORDR )            { readTable( "$pwdDir/DISCARD_ORDR.lst", $prevCards ); print "items on order\n"; }
		elsif ( $policy == $SCTL )            { readTable( "$pwdDir/DISCARD_SCTL.lst", $prevCards ); print "serials\n"; }
		elsif ( $policy == ( $HTIT | $LCPY ) ){ readTable( "$pwdDir/DISCARD_LCHT.lst", $prevCards ); print "last copy with holds\n"; }
		elsif ( $policy == $HCPY )            { readTable( "$pwdDir/DISCARD_HCPY.lst", $prevCards ); print "copy holds\n"; }
		else  { print "unknown '$policy'\n"; }
		while ( my ($key, $value) = each( %$discardHashRef ) )
		{
			if ( ( $policy & $value ) == $policy )
			{
				# print OUT "$key\n";
				$prevCards->{ $key } = 1;
				# remove the item from the list of discards since the policy matches a 'keep' policy.
				# -------------------------
				# revisit this. Chris thinks we can move all items to DISCARD since the remove report will 
				# also filter before it does its remove. The up-shot is that all the items will be moved off
				# the discard card and locatable by DISCARD location.
				# delete( $discardHashRef->{ $key } );
			}
		}
		if    ( $policy == $LCPY )            { writeTable( "$pwdDir/DISCARD_LCPY.lst", $prevCards ); }
		elsif ( $policy == $BILL )            { writeTable( "$pwdDir/DISCARD_BILL.lst", $prevCards ); }
		elsif ( $policy == $ORDR )            { writeTable( "$pwdDir/DISCARD_ORDR.lst", $prevCards ); }
		elsif ( $policy == $SCTL )            { writeTable( "$pwdDir/DISCARD_SCTL.lst", $prevCards ); }
		elsif ( $policy == ( $HTIT | $LCPY ) ){ writeTable( "$pwdDir/DISCARD_LCHT.lst", $prevCards ); }
		elsif ( $policy == $HCPY )            { writeTable( "$pwdDir/DISCARD_HCPY.lst", $prevCards ); }
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
	elsif ( $keyWord eq "WITH_TITLE_HOLDS" )    { print "checking T holds ";   $results = `cat $tmpFileName | selhold -t"T" -iC -j"ACTIVE" -oI  2>/dev/null`; }
	elsif ( $keyWord eq "WITH_COPY_HOLDS" )     { print "checking C holds ";   $results = `cat $tmpFileName | selhold -t"C" -iC -j"ACTIVE" -oI  2>/dev/null`; }
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
		elsif ( $keyWord eq "WITH_COPY_HOLDS" )  	{ $discardHashRef->{ $itemKey } |= $HCPY; }
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

# Updates the list of discard cards with dates and totals for cards that have changes.
# param:  card key hash reference key:userKey, value:total.
# param:  entire list of cards.
# return: new list of all cards with any changes recorded.
sub updateResults
{
	my ( $cardHashRef, @cards ) = @_;
	my @finishedCards = ();
	foreach ( @cards )
	{
		# and this from the finished_discards.txt file:
		# WOO-DISCARDCA6|671191|XXXWOO-DISCARD CAT ITEMS|20100313|20120507|1646|0|0|OK|00000000|0|
		my ($id, $userKey, $description, $dateCreated, $dateUsed, $itemCount, $holds, $bills, $status, $dateConverted, $converted) = split('\|', $_);
		if ( $cardHashRef->{ $userKey } )
		{
			$dateConverted = $today;
			$converted     = $cardHashRef->{ $userKey };
		}
		# reconstitute the record for writing to file
		my $record = "$id|$userKey|$description|$dateCreated|$dateUsed|$itemCount|$holds|$bills|$status|$dateConverted|$converted|";
		# print " processed: $record\n";
		# rebuild the entry for writing to file.
		push( @finishedCards, $record );
	}
	return @finishedCards;
}

# Creates a new list of discard cards.
# param:  file name string - path to where to put the discard list.
# return: 
# side effect: creates a discard file in the argument path.
sub resetDiscardList()
{
	my $results = `$apiReportDISCARDStatus`;
	my @cards = split( "\n", $results );
	my @finalSelection = ();
	foreach ( sort( @cards ) )
	{
		if ( $_ =~ m/DISCARDUNC/ or $_ =~ m/EPL-WEED/ ) # only keep UNC discard entries.
		{
			next;
		}
		if ( $_ =~ m/DISCARD-BTGFTG/ or $_ =~ m/WITHDRAW-THIS-ITEM/ or $_ =~ m/ILS-DISCARD/ )
		{
			next;
		}
		push( @finalSelection, $_."00000000|0|" );
	}
	writeDiscardCardList( @finalSelection );
}

# Kicks off the setting of various switches.
# param:
# return:
sub init()
{
    my $opt_string = 'b:Bcdem:Mn:oQrRt:x';
    getopts( "$opt_string", \%opt ) or usage();
    usage() if ($opt{'x'});                            # User needs help
    $targetDicardItemCount = $opt{'n'} if ($opt{'n'}); # User set n
    if ($opt{'r'})
    {
        resetDiscardList();
		exit( 1 );
    }
	if ( $opt{'t'} )
	{
		# cleanup files that are dangerous to have around: $requestFile, $tmpFileName.
		# request will have API commands which we don't run twice and tmpFileName will contain
		# item keys from another process.
		unlink( $requestFile ) if ( -s  $requestFile );
		unlink( $tmpFileName ) if ( -s  $tmpFileName );
		chomp( my $name = `echo $opt{'t'} | seluser -iK -oB 2>/dev/null` );
		chop( $name ); # remove the trailing '|'.
		my $result = selectReportPrepareTransactions( $opt{'t'}, $name );
		print "$result items discarded from card: $opt{'t'}\n" if ( $result );
		`apiserver -h <$requestFile >>$responseFile`;
		exit( 1 );
	}
	
	# Option 'e' converts the pipe-delimited data into an excel file. There is a requirement
	# for excel.pl to be executable in custombin.
	# param:  none
	# return: none
	if ( $opt{'e'} )
	{
		exportDiscardList( );
		exit( 1 );
	}
	# Creates lists of items left in location DISCARD catagorized by the policy they offend.
	if ( $opt{'o'} )
	{
		# Get a list of items from the DISCARD location.
		my $itemListResults    = `selitem -m"DISCARD" -oI 2>/dev/null`;
		
		my @itemKeyBarcodeList = split( "\n", $itemListResults );
		my $discardHashRef     = {};
		foreach my $line ( @itemKeyBarcodeList )
		{
			my ( $catKey, $callSeq, $copyNumber ) = split( '\|', $line );
			$discardHashRef->{ "$catKey|$callSeq|$copyNumber|" } = $DISC;
		}
		# write the file that API calls will work against.
		open( TMP, ">$tmpFileName" ) or die "Error writing to '$tmpFileName': $!\n";
		for my $key ( keys %$discardHashRef )
		{
			print TMP "$key\n";
		}
		close( TMP );
		# mark the items with against which policy they offend.
		markItems( "LAST_COPY", $discardHashRef );
		markItems( "WITH_BILLS", $discardHashRef );
		markItems( "WITH_ORDERS", $discardHashRef );
		markItems( "ARE_ACCOUNTABLE", $discardHashRef );
		markItems( "UNDER_SERIAL_CONTROL", $discardHashRef );
		markItems( "WITH_TITLE_HOLDS", $discardHashRef );
		markItems( "WITH_COPY_HOLDS", $discardHashRef );
		# report the results.
		my $totalDiscards  = reportAppliedPolicies( $discardHashRef, @EPLPreservePolicies );
		print "Total DISCARD location total: $totalDiscards.\n";
		exit( 0 );
	}
}

# Writes the list of discard cards to an excel file.
# param:  file Name string - name of the file to write. Will clobber any existing file with same name.
# return: 
# side effect: writes an excel file in the chosen directory.
sub exportDiscardList( )
{
	my @cards = readDiscardCardList();
	open( EXCEL, "| excel.pl -t 'Patron ID|Name|Created|L.A.D|No. of Charges|No. of Converts|' -o $excelFile -fggddnn" )
		or die "Failed to write to excel file $!\n";
	foreach( @cards )
	{
		my ($id, $userKey, $description, $dateCreated, $dateUsed, $itemCount, $holds, $bills, $status, $dateConverted, $converted) = split('\|', $_);
		print EXCEL "$id|$description|$dateCreated|$dateUsed|$itemCount|$converted|\n";
	}
	close( EXCEL );
}

# Prints a formated report of card condition.
# param:  hash reference of the DISCARD cards.
# param:  hash reference of the DISCARD card names.
# param:  sumCardsDone integer - of cards done.
# param:  totalCards integer - total number of cards.
# param:  totalItems integer - total number of items for discard.
# return: string report with summary.
sub showReports( $$$$$ )
{
	my ( $cardHashRef, $cardNamesRef, $sumCardsDone, $totalCards, $totalItems ) = @_;
	reportStatus( "Over quota cards:", $cardHashRef, $C_OVERLOADED, $cardNamesRef ) if ( $opt{'Q'} );
	reportStatus( "Incorrect profile of DISCARD:", $cardHashRef, $C_MISNAMED, $cardNamesRef ) if ( $opt{'M'} );
	reportStatus( "BARRED cards:", $cardHashRef, $C_BARRED, $cardNamesRef ) if ( $opt{'B'} );
	reportStatus( "Recommended cards:", $cardHashRef, $C_RECOMMEND, $cardNamesRef ) if ( $opt{'R'} );
	
	my $report = "Discard status:\n";
	# TODO report the number of items on each of the bins.
	# report the percent of list complete.
	$report .= "$sumCardsDone of $totalCards cards converted to date (".ceil(($sumCardsDone / $totalCards) * 100)."\%)\n"; 
	# report the number of items waiting for REMOVE.
	$report .= "$totalItems waiting for remove.\n";
	# remind the user to REMOVE items.
	$report .= "Please don't forget to run remove report if it isn't scheduled.\n";
	return $report;
}

# Scans the discard cards for their general condition.
# param:  sortedCards list - sorted list of cards.
# return: total number of items reported on recommended cards. This number
#         includes copies with holds, items with bills etc.
sub scanDiscardCards
{
	my ( $cardHashRef, $cardNamesHashRef, @sortedCards ) = @_;
	# set the allowable over-limit value. To adjust change fudgefactor above.
	$targetDicardItemCount = $targetDicardItemCount * $fudgeFactor + $targetDicardItemCount;
	print "discard item goal: $targetDicardItemCount\n";
	my $runningTotal   = 0; # keep tally of items to convert so we know when to stop with recommandations.
	my $totalCardsDone = 0; # total cards converted to date, used for reporting when conversion is done.
	foreach ( @sortedCards )
	{
		print "processing: $_\n" if ( $opt{'d'} );
		# split the fields so we can capture the reporting details:
		# WOO-DISCARDCA6|671191|XXXWOO-DISCARD CAT ITEMS|20100313|20120507|1646|0|0|OK|00000000|0|
		my ($id, $userKey, $description, $dateCreated, $dateUsed, $itemCount, $holds, $bills, $status, $dateConverted, $converted) = split('\|', $_);
		my $branchCode = substr($id, 0, 3);
		$cardHashRef->{ $userKey } = $C_OK;
		# let's do some reporting on the health of the cards:
		if ($id =~ m/^\d{5,}/)
		{
			$cardHashRef->{ $userKey } |= $C_MISNAMED;
		}
		if ( $status =~ m/BARRED/ )
		{
			$cardHashRef->{ $userKey } |= $C_BARRED;
		}
		if ($itemCount > $targetDicardItemCount)
		{
			$cardHashRef->{ $userKey } |= $C_OVERLOADED;
		}
		if ( $dateConverted > 0 ) # skip card if it has already been converted.
		{
			$cardHashRef->{ $userKey } |= $C_CONVERTED;
			$totalCardsDone += 1;
		}
		# Test if we are looking for a specific branch and if this card doesn't match skip it.
		elsif ( $opt{'b'} and $opt{'b'} =~ m/($branchCode)/ )
		{
			$cardHashRef->{ $userKey } |= $C_RECOMMEND;
		}
		elsif ( ( $itemCount + $runningTotal ) <= $targetDicardItemCount and $dateConverted == 0 )
		{
			$cardHashRef->{ $userKey } |= $C_RECOMMEND;
			# update the running total
			$runningTotal += $itemCount;
		}
		$cardNamesHashRef->{ $userKey } = $id;
	}
	return ( $totalCardsDone, scalar( @sortedCards ) );
}

# Selects cards for conversion. This means that we look at the total items
# on the card as a rough guide to how many will be converted.
# param:  cardHashRef hash reference - keys: userId, or card's key, values: bitmap of cards condition.
# param:  cardNamesHashRef hash reference - of card names keyed by user key of discard card.
# param:  totalsHashRef hash reference - of card names keyed by total items converted as value.
# return: hash reference of userKeys and total converted.
sub convert( $$$ )
{
	my ( $cardsHashRef, $cardNamesHashRef, $totalsHashRef ) = @_;
	my $totalItems = 0;
	while ( my ( $userKey, $bitMap ) = each( %$cardsHashRef ) )
	{
		if ( ( $bitMap & $C_RECOMMEND ) == $C_RECOMMEND )
		{
			# output all the valid item keys to file ready for APIServer command.
			my $converted = selectReportPrepareTransactions( $userKey, $cardNamesHashRef->{ $userKey } );
			if ( $converted ) # if conversion successful.
			{
				$totalsHashRef->{ $userKey } = $converted;
				$totalItems += $converted;
			}
		}
	}
	return $totalItems;
}

# Sends mail message.
# param:  subject string.
# param:  addressees string, space separated valid email addresses.
# param:  mail string content of the message to send.
# return: 
sub mail( $$$ )
{
    #-- send an email to user@localhost
    my ( $subject, $addressees, $mail ) = @_;
    open(MAIL, "| /usr/bin/mailx -s $subject $addressees") || die "mailx failed: $!\n";
    print MAIL "$mail\nSigned: Discard.pl\n";
    close(MAIL);
}

# Prints a report of the of the argument hash reference.
# param: report title
# param: items hash reference of items to be reported.
# param: bit flag for the item being reported.
# param: names of the cards as a hash ref with keys: card key, and value: name.
# return: string containing report results.
sub reportStatus( $$$$ )
{
    my ( $reportMessage, $items, $whichBit, $cardNames ) = @_;
	my ( $key, $value, $cardName );
	format RPT_STATUS_TITLE=

@<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
$reportMessage
-------------------------------------
.
	format RPT_STATUS_COUNTS = 
@<<<<<<<<<<<<<
$cardName
.
	$~ = "RPT_STATUS_TITLE";
	write;
	$~ = "RPT_STATUS_COUNTS";
	while ( ( $key, $value ) = each( %$items ) )
	{
		if ( ( $value & $whichBit ) == $whichBit ) 
        {
			$cardName = $cardNames->{ $key };
			write;
		}
	}
	$~ = "STDOUT";
}

################
# Main entry
init();

# create a new list if one doesn't exist yet.
resetDiscardList() if ( not -s $discardsFile );
my @cards          = readDiscardCardList();
my $cardHashRef    = {};
my $cardNamesHashR = {};
my $convertHashRef = {};
my $totalItems     = 0;
# card scanning sets bitmask including any convert recommendations.
my ( $cardsDone, $cardsTotal ) = scanDiscardCards( $cardHashRef, $cardNamesHashR, @cards ); 
if ( $cardsDone >= $cardsTotal )
{
	# If the list is finished back it up and remove it.
	exportDiscardList( );
	my $report = "Discard cycle complete.\n ";
	if ( -s "$excelFile" )
	{
		unlink( $discardsFile );
		$report .= "'$discardsFile' backed up to '$excelFile'.\nCreating new list.\n";
		resetDiscardList();
		mail( "Discard Report", $opt{'m'}, $report ) if ( $opt{'m'} );
	}
	else
	{
		$report .= "couldn't backup '$discardsFile'. Not removing, but discards can't proceed until this list is removed.\n";
		mail( "Discard Report", $opt{'m'}, $report ) if ( $opt{'m'} );
	}
	exit( $ALL_CARDS_CONVERTED );
}
if ( $opt{'c'} )
{
	# cleanup files that are dangerous to have around: $requestFile, $tmpFileName.
	# request will have API commands which we don't run twice and tmpFileName will contain
	# item keys from another process.
	unlink( $requestFile ) if ( -s  $requestFile );
	unlink( $tmpFileName ) if ( -s  $tmpFileName );
	# TODO repeat this step for more items if the actual counts are low.
	$totalItems = convert( $cardHashRef, $cardNamesHashR, $convertHashRef );
	# run the apiserver with the commands to convert the discards.
	# `apiserver -h <$requestFile >>$responseFile`;
}
@cards = updateResults( $convertHashRef, @cards );
# Write the file out again.
writeDiscardCardList( @cards );
# write report
my $report = showReports( $cardHashRef, $cardNamesHashR, $cardsDone, $cardsTotal, $totalItems );
mail( "Discard Report", $opt{'m'}, $report ) if ( $opt{'m'} );
1;
