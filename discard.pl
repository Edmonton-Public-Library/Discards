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
#          3.18.02 - Add switch to select items checked out to discard in days. 
#          3.18.01 - Fix bug that wasn't testing or producing sorted files. 
#          3.18 - Normalize functions. 
#          3.17.01 - Merged code from test bench discardlastcopy.pl. 
#          3.17 - Bug fix for incorrect recording of discard types per file. 
#          3.16 - Bug fix for incomplete selection of last viable copy. 
#          3.15 - Expands selection of last copy to a super set of all discard items whose siblings are also in 
#          any of the inaccessible locations of DAMAGE, LOST, LOST-ASSUM, and LOST-CLAIM.
#          3.1 - Removes item keys listed in the deny list just before conversion '-y' is invoked. See usage.
#          3.04- Overwrite existing exception files.
#          3.03- Improve maintenance of finished_discard.txt file. This file will take the existing convert count and add
#          to it, then save it back.
#          3.02- Improved the LAST COPY search so that it works for Last copy of a title; before it was per callnum.
#          3.01- Modified reporting of cards reporting catagories counts and card keys.
#          3.0 - Modified code to use -i to read a list of long-checked-out discard items produced by
#          'longcheckedout.pl -d"some/path"'.
#          2.0 - By default gives cards with incorrect profile a convert date so they are skipped. Refactored
#          code base and tested against new epl.pm which would fail if the table it was trying to read didn't exist.
#          general code fixes and simplified argument passing. Added validateCards at the beginning to handle 
#          cards that have item counts of 0 or are mis-named. Removed formatting from report in favour of pipe-delimited
#          text report. -Q, -M, -R and -B all show the same information but are not included in the report by default.
#          1.6.2 - Fixed bug that didn't select by branch correctly, and now selects by branch and keeps item count below threshold.
#          1.6.1 - Now uses epl.pm lib.
#          1.6 - Modified convert loop to select more cards and libs for epl.
#          1.5 - APIConverts incorporated.
#          1.0 - Production
#          0.0 - develop
#          July 3, 2012 - Cards available not reporting branches' barred cards
#          July 19, 2012 - Added '-fggddnn' and made consistent opt quoting.
#
########################################################################
BEGIN # Required for any script that requires the use of epl.pm or other custom modules.
{
	push @INC, "/s/sirsi/Unicorn/EPLwork/epl_perl_libs";      # This is for running 
	push @INC, "/home/ilsdev/projects/epl_perl_libs"; # This is so we can test compile and run on dev machine
}
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

my $VERSION               = "3.18.02";
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
my @EPLPreservePolicies = ( $HTIT, $LCPY, $BILL, $ORDR, $SCTL, $HCPY );
chomp( my $discardRetentionPeriod  = `transdate -d-90` );
#chomp( my $discardRetentionPeriod = `transdate -d-0` ); # just for testing.
my $targetDiscardItemCount= 2000;
my $C_OK                  = 0b000001;
my $C_OVERLOADED          = 0b000010;
my $C_BARRED              = 0b000100;
my $C_MISNAMED            = 0b001000;
my $C_RECOMMEND           = 0b010000; # recommended cards get selected for conversion.
my $C_CONVERTED           = 0b100000;
chomp( my $today          = `transdate -d+0` );
chomp( my $tmpDir         = `getpathname tmp` );
my $pwdDir                = qq{/s/sirsi/Unicorn/EPLwork/cronjobscripts/Discards};
# my $pwdDir                = qq{./};
my $tmpFileName           = qq{$tmpDir/tmp_a};
my $discardsFile          = qq{$pwdDir/finished_discards.txt}; # Name of the discards file.
my $requestFile           = qq{$pwdDir/DISCARD_TXRQ.cmd};
my $responseFile          = qq{$pwdDir/DISCARD_TXRS.log};
my $excelFile             = qq{$pwdDir/Discards$today.xls};
my @NON_VIABLE_LOCATIONS  = qw( DISCARD );

#
# Message about this program and how to use it
#
sub usage()
{
    print STDERR << "EOF";

This script determines the recommended DISCARD cards to convert based on
the user specified max number of items to process - default: 2000.

*** WARNING ***
Over quota cards will stop a new list from being generated because the 
list can't be finished.
*** WARNING ***

usage: $0 [-bBceMorRQx] [-n number_items] [-m email] [-t cardKey] [-i path] [-h days]

 -B        : reports cards that have BARRED status.
 -b BRAnch : request a specific branch for discards. Selecting a branch must
             be done by the 3-character prefix of the id of the card (WOO-DISCARDCA7
             would be 'WOO') and is uc/lc sensitive. Also all the cards from that
             branch will be checked and converted if -c was selected. 
 -c        : convert the recommended cards automatically.
 -d        : turn on debugging output.
 -e        : write the current finished discard list to MS excel format.
             default name is 'Discard[yyyymmdd].xls'.
 -h days   : process items from the given number of days ago (default 90). Like -h-60
             for 60 days ago.
 -i path   : process items from an 'allow' list. See -y for 'deny' list processing.
 -l "LOC0,LOC1": Locations where items are considered non-viable. DISCARD is the default.
 -m "addrs": mail output to provided address(es).
 -M        : reports cards that are incorrectly identified with DISCARD profile.
 -n number : sets the upper limit of the number of discards to process.
 -o        : report all items from the DISCARD location. Creates lists of those item's
             retension reason.
 -Q        : reports cards that are over-quota.
 -r        : reset the list. Re-reads all discard cards and creates a new list.
             other flags have no effect.
 -R        : reports cards that are recommended for conversion.
 -t cardKey: convert the card with this key.
 -x        : this (help) message
 -y path   : deny list of item keys. Stops these item keys from being converted.
             Has no effect without '-c', or if the specified list is missing, empty
             or contains no item keys that match those selected for conversion.
             Items on this list always trump items on an 'allow' list, that is,
             if an item shows up on the allow and deny list the item will NOT be
             converted. Deny has no effect on reporting. Deny files are just item
             keys - one per line. The file can be named anything.
			 
example: $0 -ecq -n 1500 -m anisbet\@epl.ca -b MNA
example: $0 -n 2500 -m anisbet\@epl.ca -i"./LCOdiscard.lst"
example: $0 -n 2500 -m anisbet\@epl.ca -i"./item_keys_to_discard.lst" -y"./some_item_keys_to_keep.lst"
example: $0 -i"./item_keys_to_discard.lst" -y"./some_item_keys_to_keep.lst" -l"DAMAGE,LOST,LOST-ASSUM,LOST-CLAIM".
example: $0 -h60 -o -l"DAMAGE,LOST,LOST-ASSUM,LOST-CLAIM".
Version: $VERSION

EOF
    exit;
}

# Writes the contents of a hash reference to file. Values are not stored.
# param:  file name string - path of file to write to.
# param:  table hash reference - data to write to file (keys only).
# return: the number of items written to file.
sub writeTable( $$ )
{
	my $fileName = shift;
	my $table    = shift;
	open TABLE, ">$fileName" or die "**Error: discard serialization error writing '$fileName' $!\n";
	for my $key ( sort keys %$table )
	{
		print TABLE "$key\n";
	}
	close TABLE;
	return scalar keys %$table;
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

# Removes keys of items on the deny list (if any).
# param:  hash reference of discarded cat keys.
# return: 
sub removeDenyItemKeys( $ )
{
	my $discardHashRef = shift;
	print STDERR "'-y' set.\n" if ( $opt{'d'} );
	if ( -e $opt{'y'} ) # file exists.
	{
		print STDERR "$opt{'y'} file is valid.\n" if ( $opt{'d'} );
		open( DENY_KEYS, "<$opt{'y'}" ) or die "Couldn't read $opt{'y'} $!\n";
		my $denyTable;
		while ( <DENY_KEYS> )
		{
			chomp;
			$denyTable->{ $_ } = 1;
		}
		close( DENY_KEYS );
		for my $denyLine ( keys %$denyTable )
		{
			# On a discard list the item keys look like this:
			# "338579|29|1|201212211414|SPW-DISCARD2|DISCARD|EPLSPW|417|0|0|625144|BARRED|"
			# but the item key is at the beginning so check the keys if they start with the deny item keys
			print STDERR "DENY_KEY '$denyLine'\n" if ( $opt{'d'} );
			my @fields  = split( '\|', $denyLine ); # during testing we were using part of the allow list so just get the item keys.
			my $denyKey = "";  
			if ( exists $fields[0] and exists $fields[1] and exists $fields[2] )
			{
				# joining will put a literal '\|' which you need for matching or regex engine sees it as '|' separated expressions.
				$denyKey = join( '\|', $fields[0], $fields[1], $fields[2] ); # match if the item key is specified along with anything else.
			}
			elsif ( exists $fields[0] and exists $fields[1] )
			{
				$denyKey = join( '\|', $fields[0], $fields[1] ); # match if the call num is given
			}
			elsif ( exists $fields[0] )
			{
				$denyKey = $fields[0]; # match if only the cat key is given
			}
			if ( $denyKey eq "" )
			{
				next; # empty line, or no value set for deny key but if you don't skip '' **will match** any line.
			}
			for my $allowItemKey ( keys %$discardHashRef ) 
			{
				if ( $allowItemKey =~ m/^($denyKey)/ )
				{
					delete( $discardHashRef->{$allowItemKey} );
					print STDERR "REMOVE MATCH: '$allowItemKey' and '$denyKey'\n" if ( $opt{'d'} );
				}
			}
		}
	}
	return;
}

# Creates entries that will move all items to location DISCARD via 
# a API server transaction file.
# param:  hash reference of discarded cat keys.
# return: count of items moved.
sub createAPIServerTransactions( $ )
{
	my ( $discardHashRef ) = shift;
	# first job: if '-y' is selected remove these items.
	removeDenyItemKeys( $discardHashRef ) if ( $opt{'y'} );
	# next create a file of the cat keys we have left on the hash ref.
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
sub selectReportPrepareCardTransactions( $ )
{
	my $cardKey        = shift;
	# return 555; # Use this to test return bogus results for reports and finished discard file.
	my $discardHashRef = getDiscardedItemsFromCard( $cardKey, $discardRetentionPeriod );
	writeTable( $tmpFileName, $discardHashRef );
	markItems( "LAST_COPY", $discardHashRef );
	markItems( "WITH_BILLS", $discardHashRef );
	markItems( "WITH_ORDERS", $discardHashRef );
	markItems( "ARE_ACCOUNTABLE", $discardHashRef );
	markItems( "UNDER_SERIAL_CONTROL", $discardHashRef );
	markItems( "WITH_TITLE_HOLDS", $discardHashRef );
    markItems( "WITH_COPY_HOLDS", $discardHashRef );
	my $totalDiscards  = reportAppliedPolicies( $discardHashRef, @EPLPreservePolicies );
	print "Total discards to process: $totalDiscards items.\n" if ( $opt{'d'} );
	# move all discarded items to location DISCARD.
	my $convertCount   = createAPIServerTransactions( $discardHashRef );
	return $convertCount; # returns the number of items converted.
}

# This function performs all the high level activities of converting items
# to discard, with the exception of actually running the apiserver. This is 
# because we want to append all server transactions to one file an then run 
# it after all cards for the day have been converted. The apiserver is much
# more efficient if we run the apiserver against all.
# param:  path to the long-checked-out discard file.
# param:  hash reference of all the discard cards key:User Key value: items converted.
# return: integer number of cards converted or zero if none or on failure.
sub selectReportPrepareItemTransactions( $$ )
{
	my $longCheckedOutDiscardFile = shift;
	my $convertedCardsHashRef     = shift;
	# return 555; # Use this to test return bogus results for reports and finished discard file.
	my $discardHashRef = getItemsFromLongCheckedOutList( $longCheckedOutDiscardFile, $convertedCardsHashRef );
	writeTable( $tmpFileName, $discardHashRef );
	markItems( "LAST_COPY", $discardHashRef );
	markItems( "WITH_BILLS", $discardHashRef );
	markItems( "WITH_ORDERS", $discardHashRef );
	markItems( "ARE_ACCOUNTABLE", $discardHashRef );
	markItems( "UNDER_SERIAL_CONTROL", $discardHashRef );
	markItems( "WITH_TITLE_HOLDS", $discardHashRef );
    markItems( "WITH_COPY_HOLDS", $discardHashRef );
	my $totalDiscards  = reportAppliedPolicies( $discardHashRef, @EPLPreservePolicies );
	my $listSize       = getLongCheckedOutListSize();
	print "Total discards to process: $totalDiscards of $listSize items.\n" if ( $opt{'d'} );
	# move all discarded items to location DISCARD.
	my $convertCount   = createAPIServerTransactions( $discardHashRef );
	return $convertCount; # returns the number of items converted.
}

# Returns the number of discarded items on the long-checked-out list.
# param:  
# return: int number of items on the list.
sub getLongCheckedOutListSize()
{
	my $count = 0;
	open( LIST, "<$opt{'i'}" ) or die "Error: failed to read $opt{'i'}, $!\n";
	$count++ while (<LIST>);
	close( LIST );
	return $count;
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
	foreach my $policy ( @policies )
	{
		my $itemsThatMatchThisPolicy = {};
		while ( my ( $key, $v ) = each( %$discardHashRef ) )
		{
			if ( ( $v & $policy ) == $policy )
			{
				$itemsThatMatchThisPolicy->{ $key } = 1;
			}
		}
		if    ( $policy == $LCPY ) { writeTable( "$pwdDir/DISCARD_LCPY.lst", $itemsThatMatchThisPolicy ); }
		elsif ( $policy == $BILL ) { writeTable( "$pwdDir/DISCARD_BILL.lst", $itemsThatMatchThisPolicy ); }
		elsif ( $policy == $ORDR ) { writeTable( "$pwdDir/DISCARD_ORDR.lst", $itemsThatMatchThisPolicy ); }
		elsif ( $policy == $SCTL ) { writeTable( "$pwdDir/DISCARD_SCTL.lst", $itemsThatMatchThisPolicy ); }
		elsif ( $policy == $HTIT ) { writeTable( "$pwdDir/DISCARD_HOLD.lst", $itemsThatMatchThisPolicy ); }
		elsif ( $policy == $HCPY ) { writeTable( "$pwdDir/DISCARD_HCPY.lst", $itemsThatMatchThisPolicy ); }
		for (keys %$itemsThatMatchThisPolicy)
		{
			delete $itemsThatMatchThisPolicy->{ $_ };
		}
	}
	# And write to one big file with the additional policy flags attached.
	my $flaggedCards = {};
	while ( my ($key, $v) = each( %$discardHashRef ) )
	{
		$flaggedCards->{ "$key$v|" } = 1;
	}
	writeTable( "DISCARD_COMP.lst", $flaggedCards );
	return scalar( keys( %$discardHashRef ) );
}

# This function finds all the siblings of the argument item key, 
# that are mutually inaccessible, that is, a family of items that
# are all in inaccessible locations of DAMAGE, LOST, LOST-ASSUM, 
# or LOST-CLAIM.
# param:  file of item keys. 
# params: all other params are the list of non-viable locations.
#         DISCARD,DAMAGE,LOST,LOST-ASSUM, and LOST-CLAIM
# return: a string of item keys separated by a '\n'.
sub findNonViableTitles
{
	my $fileName = shift;
	# It will be faster to look up non viable locations if we put them in a hash.
	# Non-viable lookup time drops to O(1).
	my %nonViableLocations      = map { $_ => 1 } @_;
	my $nonViableItemKeyString  = "";  # Contains the entire list of item keys that are not viable.
	my $viableLocationCount     = 0;   # count of viable locations for the current title.
	my $lastCKey                = 0;   # Item key of the last iteration.
	my $lastSequenceNumber      = 0;   # Call sequence of ...
	my $lastCopyNumber          = 0;   # Last copy number of ...
	my @potentialNonViableKeys  = ();
	my $forsureNonViableKeys    = {};
	# Get all the items for all the titles associated with the discarded item keys.
	my $result = `cat "$fileName" | selitem -iC -oCmI 2>/dev/null`;
	my @entireList = split( '\n', $result );
	for my $line  ( sort( @entireList ) )
	{
		my ( $cKey, $loc, $catKey, $seqNumber, $itemNumber ) = split( '\|', $line );
		if ( $lastCKey != $cKey && $lastCKey != 0 )
		{
			if ( $viableLocationCount == 0 )
			{
				for my $nonViableRecord ( @potentialNonViableKeys )
				{
					print "NON-VIABLE: $nonViableRecord" if ( $opt{ 'd' });
					$forsureNonViableKeys->{ $nonViableRecord } = 1;
				}
			}
			$viableLocationCount = 0;
			undef @potentialNonViableKeys;
			@potentialNonViableKeys = ();
		}
		$lastCKey           = $catKey;
		$lastSequenceNumber = $seqNumber;
		$lastCopyNumber     = $itemNumber;
		# if the item's current location is not in the non-viable location list then it 
		# must be in a viable location, and there for there must be at least one viable copy 
		# left in the catalogue.
		if( exists( $nonViableLocations{ $loc } ) )
		{
			# save the item key for potentially return list.
			if ( $loc eq "DISCARD" ) # only save the discard keys.
			{
				push( @potentialNonViableKeys, "$lastCKey|$lastSequenceNumber|$lastCopyNumber|\n" );
			}
		}
		else
		{
			$viableLocationCount += 1;
		}
	}
	# do the last iteration
	if ( $viableLocationCount == 0 )
	{
		for my $nonViableRecord ( @potentialNonViableKeys )
		{
			print "NON-VIABLE: $nonViableRecord" if ( $opt{ 'd' });
			$forsureNonViableKeys->{ $nonViableRecord } = 1;
		}
	}
	undef @potentialNonViableKeys;
	# create a result set.
	while( my ($key, $v) = each %$forsureNonViableKeys ) 
	{
		$nonViableItemKeyString .= "$key";
	}
	for ( keys %$forsureNonViableKeys )
    {
        delete $forsureNonViableKeys->{$_};
    }
	return $nonViableItemKeyString;
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
sub markItems( $$ )
{
	my ( $keyWord, $discardHashRef ) = @_;
	my $results  = "";
	# This next line is naive. It returns call nums that have less than 2 copies for a callnum!
	# A title can have several call numbers. Some on order with copies less than two copies, but we really need 
	# are the Titles with less than 2 copies. head -1 DISCARD_LCHT.lst | selcallnum    -iC -c"<2"     -oC | sort | uniq -c
	# produces:    8 1016142|
	# We don't need this one because the title has 8 copies.
	# cat DISCARD_LCHT.lst | selcatalog -iC -n"<2" -oCS | selcallnum  -iN -c"<2" -oNS
	# prints out the cat key we could use that to do a lookup for items keys that start with that catalog key.
	# But even that will give you on order copies, we need to take the ones above that have count 0 then selcatalog
	# if    ( $keyWord eq "LAST_COPY" )           { $results = `cat $tmpFileName | selcallnum    -iN -c"<2"     -oNS 2>/dev/null`; }
	# This line finds all of the literally last items on a title. This works but we need something that finds last VIABLE item on a title.
	# if    ( $keyWord eq "LAST_COPY" )           { $results = `cat $tmpFileName | selcatalog -iC -n"<2" -oCS | selcallnum  -iN -c"<2" -oNS 2>/dev/null`; }
	# This computes the last Viable item of a title.
	if    ( $keyWord eq "LAST_COPY" )           { $results = findNonViableTitles( $tmpFileName, @NON_VIABLE_LOCATIONS ); }
	elsif ( $keyWord eq "WITH_BILLS" )          { $results = `cat $tmpFileName | selbill       -iI -b">0.00"  -oI  2>/dev/null`; }
	elsif ( $keyWord eq "WITH_ORDERS" )         { $results = `cat $tmpFileName | selorderlin   -iC            -oCS 2>/dev/null`; }
	elsif ( $keyWord eq "UNDER_SERIAL_CONTROL" ){ $results = `cat $tmpFileName | selserctl     -iC            -oCS 2>/dev/null`; }
	elsif ( $keyWord eq "WITH_TITLE_HOLDS" )    { $results = `cat $tmpFileName | selhold -t"T" -iC -j"ACTIVE" -oI  2>/dev/null`; }
	elsif ( $keyWord eq "WITH_COPY_HOLDS" )     { $results = `cat $tmpFileName | selhold -t"C" -iC -j"ACTIVE" -oI  2>/dev/null`; }
	else  { print "skipping: '$keyWord'\n" if ( $opt{'d'} ); return; }
	my @itemList  = split( '\n', $results );
	print "completed, ".scalar( @itemList )." related hits\n" if ( $opt{'d'} );
	foreach my $itemKey ( @itemList )
	{
		# some commands only take a cat key and produce many results with item keys that don't match. This is especially
		# true for test data sets. Only update the values of item keys that match.
		if ( exists $discardHashRef->{ $itemKey } )
		{
			if    ( $keyWord eq "LAST_COPY" )           { $discardHashRef->{ $itemKey } |= $LCPY; }
			elsif ( $keyWord eq "WITH_BILLS" )          { $discardHashRef->{ $itemKey } |= $BILL; }
			elsif ( $keyWord eq "WITH_ORDERS" )         { $discardHashRef->{ $itemKey } |= $ORDR; }
			elsif ( $keyWord eq "UNDER_SERIAL_CONTROL" ){ $discardHashRef->{ $itemKey } |= $SCTL; }
			elsif ( $keyWord eq "WITH_TITLE_HOLDS" )    { $discardHashRef->{ $itemKey } |= $HTIT; }
			elsif ( $keyWord eq "WITH_COPY_HOLDS" )  	{ $discardHashRef->{ $itemKey } |= $HCPY; }
			else  { ; }
		}
	}
}

# Gets upto the specified number of items from the long-checked-out list.
# param:  path to the long-checked-out discard file.
# param:  hash reference of converted cards key: user_key value: converted count.
# return: hash reference keys: item key, values: 1.
sub getItemsFromLongCheckedOutList( $$ )
{
	my $LCHODiscardList    = shift;
	my $discardCardHashRef = shift;
	open( LCOL, "<$LCHODiscardList" ) or die "Error, $LCHODiscardList: $!\n";
	my $itemKeyHashRef = {};
	while( <LCOL> )
	{
		# stop if we have exceeded the maximum number of discards for today.
		last if ( keys %$itemKeyHashRef  >= $targetDiscardItemCount );
		# a line out of the longcheckedout.lst looks like:
		# cat key|seq|copy num|datelastactivity|UserBC|Profile|Lib|Charges|Holds|Bills|User key|status|
		# 1012012|1|1|201208221607|LON-DISCARD4|DISCARD|EPLLON|1745|0|0|612885|BARRED|
		my ( $catKey, $callSeq, $copyNumber, $dateTime, $barcode, $profile, $library, $charges, $holds, $bills, $userKey, $status ) = split( '\|', $_ );
		$itemKeyHashRef->{ "$catKey|$callSeq|$copyNumber|" } = $DISC;
		# now add 1 to the count of items converted for converted cards.
		$discardCardHashRef->{ $userKey }++;
	}
	close( LCOL );
	return $itemKeyHashRef;
}

# Gets all of the items checked out to the argument discard card. Error 111 like:
# **error number 111 on charge read_charge_user_key start, cat=0 seq=0 copy=0 charge=0 primary=0 user=583474
# is normal for cards that have nothing charged to them.
# param:  cardKey string - User key for the discard card.
# param:  cutoffDate string - latest date to consider for search (from beginning of time to cut-off date).
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
# param:  card key hash of converted cards reference key:userKey, value:total.
# return:
sub updateResults( $ )
{
	my ( $convertedCardsHashRef ) = shift;
	my @cards = readDiscardCardList();
	my @finishedCards = ();
	foreach ( @cards )
	{
		# and this from the finished_discards.txt file:
		# WOO-DISCARDCA6|671191|XXXWOO-DISCARD CAT ITEMS|20100313|20120507|1646|0|0|OK|00000000|0|
		my ($id, $userKey, $description, $dateCreated, $dateUsed, $itemCount, $holds, $bills, $status, $dateConverted, $converted) = split('\|', $_);
		if ( exists $convertedCardsHashRef->{ $userKey } ) # value may be '0' but must be defined.
		{
			$dateConverted  = $today;
			$converted     += $convertedCardsHashRef->{ $userKey };
		}
		# reconstitute the record for writing to file
		my $record = "$id|$userKey|$description|$dateCreated|$dateUsed|$itemCount|$holds|$bills|$status|$dateConverted|$converted|";
		print " processed: $record\n" if ( $opt{'d'} );
		# rebuild the entry for writing to file.
		push( @finishedCards, $record );
	}
	writeDiscardCardList( @finishedCards )
}

# Creates a new list of discard cards.
# param:  file name string - path to where to put the discard list.
# return: 
# side effect: creates a discard file in the argument path.
sub resetDiscardList
{
	my $results = `$apiReportDISCARDStatus`;
	my @cards = split( "\n", $results );
	my @finalSelection = ();
	foreach ( sort( @cards ) )
	{
		push( @finalSelection, $_."00000000|0|" );
	}
	writeDiscardCardList( @finalSelection );
}

# Kicks off the setting of various switches.
# param:
# return:
sub init()
{
    my $opt_string = 'b:Bcdeh:i:l:m:Mn:oQrRt:xy:';
    getopts( "$opt_string", \%opt ) or usage();
    usage() if ($opt{'x'});                            # User needs help
    $targetDiscardItemCount = $opt{'n'} if ($opt{'n'}); # User set n
    if ($opt{'r'})
    {
        resetDiscardList();
		exit( 1 );
    }
	# This is not good we duplicate code in -o below, but -o operates on it's own switch set.
	if ( $opt{ 'h' } )
	{
		my $myDaysAgo = $opt{ 'h' };
		if ( $myDaysAgo =~ m/\-?\d{1,}/ )
		{
			chomp( $discardRetentionPeriod  = `transdate -d$myDaysAgo` );
		}
	}
	if ( $opt{'t'} )
	{
		# cleanup files that are dangerous to have around: $requestFile, $tmpFileName.
		# request will have API commands which we don't run twice and tmpFileName will contain
		# item keys from another process.
		unlink( $requestFile ) if ( -s  $requestFile );
		unlink( $tmpFileName ) if ( -s  $tmpFileName );
		my $result = selectReportPrepareCardTransactions( $opt{'t'} );
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
		# Non-viable locations are set here.
		if ( $opt{ 'l' } )
		{
			# looks like:
			# -l"DAMAGE,LOST,LOST-ASSUM,LOST-CLAIM".
			# needs to be made into:
			# my @NON_VIABLE_LOCATIONS  = ( "DISCARD", "DAMAGE", "LOST", "LOST-ASSUM", "LOST-CLAIM" );
			my @additionalLocations = split( ',', $opt{ 'l' } );
			foreach my $loc ( @additionalLocations )
			{
				push( @NON_VIABLE_LOCATIONS, $loc );
			}
			print "@NON_VIABLE_LOCATIONS\n"
		}
		my $itemListResults = "";
		if ( $opt{ 'h' } )
		{
			my $myDaysAgo = $opt{ 'h' };
			if ( $myDaysAgo =~ m/\-?\d{1,}/ )
			{
				chomp( $discardRetentionPeriod  = `transdate -d$myDaysAgo` );
				$itemListResults = `selitem -m"DISCARD" -n">$discardRetentionPeriod" -oI 2>/dev/null`;
			}
			else 
			{
				# User entered a date that didn't work.
				print STDERR "Error: Invalid date: '" . $opt{ 'h' } . "\n";
				usage();
			}
		}
		else
		{
			# Get a list of items from the DISCARD location.
			$itemListResults    = `selitem -m"DISCARD" -oI 2>/dev/null`;
		}
		my @itemKeyBarcodeList = split( '\n', $itemListResults );
		my $discardHashRef     = {};
		foreach my $line ( @itemKeyBarcodeList )
		{
			my ( $catKey, $callSeq, $copyNumber ) = split( '\|', $line );
			$discardHashRef->{ "$catKey|$callSeq|$copyNumber|" } = $DISC;
		}
		# write the file that API calls will work against.
		writeTable( $tmpFileName, $discardHashRef );
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
sub exportDiscardList
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
sub showReports( $ )
{
	my ( $totalItems ) = shift;
	my $cardHashRef    = validateCards();   
	my $sumCardsDone   = 0;
	my $totalCards     = scalar( keys %$cardHashRef );
	for ( keys %$cardHashRef )
	{
		$sumCardsDone++ if ( ( $cardHashRef->{ $_ } & $C_CONVERTED ) == $C_CONVERTED );
	}
	my $report = "Discard status:\n";
	# report the percent of list complete.
	if ( $opt{'i'} )
	{
		my $listSize = getLongCheckedOutListSize();
		$report .= "$totalItems of $listSize items converted (".ceil(( $totalItems / $listSize ) * 100 )."\%)\n";
	}
	else
	{
		$report .= "$sumCardsDone of $totalCards cards converted to date (".ceil(( $sumCardsDone / $totalCards ) * 100 )."\%)\n";
	}		
	# report the number of items waiting for REMOVE.
	$report .= "$totalItems items waiting for remove.\n";
	# remind the user to REMOVE items.
	$report .= "Please don't forget to run remove report if it isn't scheduled.\n";
	$report .= reportStatus( $cardHashRef ) if ( $opt{'Q'} or $opt{'M'} or $opt{'B'} or $opt{'R'} );
	return $report;
}

# Scans the discard cards for their general condition.
# param:  sortedCards hash ref. - sorted list of cards and state if any.
# param:  runningTotal int - keep tally of items to convertCard so we know when to stop with recommandations.
# return: total number of items reported on recommended cards. This number
#         includes copies with holds, items with bills etc.
sub scanDiscardCards( $$ )
{
	my ( $cardHashRef, $runningTotal ) = @_;
	my @sortedCards = sort( readDiscardCardList() );
	# empty the list of cards because we are going to reset all their bits again.
	for ( keys %$cardHashRef )
    {
        delete $cardHashRef->{$_};
    }
	# set the allowable over-limit value. To adjust change fudgefactor above.
	my $totalCardsDone = 0; # total cards converted to date, used for reporting when conversion is done.
	foreach ( @sortedCards )
	{
		print "processing: $_\n" if ( $opt{'d'} );
		# split the fields so we can capture the reporting details:
		# WOO-DISCARDCA6|671191|XXXWOO-DISCARD CAT ITEMS|20100313|20120507|1646|0|0|OK|00000000|0|
		my ($id, $userKey, $description, $dateCreated, $dateUsed, $itemCount, $holds, $bills, $status, $dateConverted, $converted) = split('\|', $_);
		$cardHashRef->{ $userKey } = $C_OK;
		# let's do some reporting on the health of the cards:
		if ( $status =~ m/BARRED/ )
		{
			$cardHashRef->{ $userKey } |= $C_BARRED;
		}
		if ($itemCount > $targetDiscardItemCount)
		{
			$cardHashRef->{ $userKey } |= $C_OVERLOADED;
		}
		if ( $dateConverted > 0 ) # skip card if it has already been converted.
		{
			$cardHashRef->{ $userKey } |= $C_CONVERTED;
			$totalCardsDone += 1;
		}
		# Check cards that have not been converted.
		else
		{
			# process only branch specific cards.
			if ( $opt{'b'} )
			{
				my $branchCode = substr($id, 0, 3);
				if ( $opt{'b'} eq $branchCode )
				{
					# ensure we don't convert too many items by branch.
					if ( ( $itemCount + $runningTotal ) <= $targetDiscardItemCount )
					{
						$cardHashRef->{ $userKey } |= $C_RECOMMEND;
						# keep track of how many items you've going to do so far
						$runningTotal += $itemCount;
					}
				}
			}
			# if NOT branch process any card that comes our way this is doesn't push us over the limit will do.
			elsif ( ( $itemCount + $runningTotal ) <= $targetDiscardItemCount )
			{
				$cardHashRef->{ $userKey } |= $C_RECOMMEND;
				# update items so far
				$runningTotal += $itemCount;
			}
		}
	}
	return $totalCardsDone;
}

# This function pre-validates cards. Pre-validation will cause cards with reported values of '0'
# and cards with incorrect profile to be skipped, but all are marked as converted so we don't 
# stop the convert process cycle. Note the implications are that skipped cards are ignored
# and, if not delt with, will continue to grow.
# param:
# return: hash reference of all cards with current status sychronized with the finished discard file.
sub validateCards
{
	my @cards = readDiscardCardList();
	# if the card is mis-named it shouldn't be recommended.
	my $cardHashRef = {};
	my @updatedCards  = ();
	foreach ( @cards )
	{
		print "pre-processing: $_\n" if ( $opt{'d'} );
		# split the fields so we can capture the reporting details:
		# WOO-DISCARDCA6|671191|XXXWOO-DISCARD CAT ITEMS|20100313|20120507|1646|0|0|OK|00000000|0|
		my ($id, $userKey, $description, $dateCreated, $dateUsed, $itemCount, $holds, $bills, $status, $dateConverted, $converted) = split('\|', $_);
		$cardHashRef->{ $userKey } = $C_OK;
		if ( $status =~ m/BARRED/ )
		{
			$cardHashRef->{ $userKey } |= $C_BARRED;
		}
		if ($itemCount > $targetDiscardItemCount)
		{
			$cardHashRef->{ $userKey } |= $C_OVERLOADED;
		}
		# skip card if it has already been converted.
		if ( $dateConverted > 0 ) 
		{
			$cardHashRef->{ $userKey } |= $C_CONVERTED;
		}
		elsif ( $itemCount == 0 )
		{
			$cardHashRef->{ $userKey } |=  $C_CONVERTED;
			$dateConverted = $today;
		}
		elsif ( $description !~ m/DISCARD/ and $id !~ m/DISCARD/ )
		{
			$cardHashRef->{ $userKey } |=  $C_MISNAMED;
			$cardHashRef->{ $userKey } |=  $C_CONVERTED;
			# turn the recommend bit off even if it is off.
			$cardHashRef->{ $userKey } &= ~$C_RECOMMEND;
			$dateConverted = $today;
		}

		# reconstitute the record for writing to file
		my $record = "$id|$userKey|$description|$dateCreated|$dateUsed|$itemCount|$holds|$bills|$status|$dateConverted|$converted|";
		print " post-processed: $record\n" if ( $opt{'d'} );
		# rebuild the entry for writing to file.
		push( @updatedCards, $record );
	}
	writeDiscardCardList( @updatedCards );
	return $cardHashRef;
}

# Selects cards for conversion. This means that we look at the total items
# on the card as a rough guide to how many will be converted.
# param:  cardHashRef hash reference - keys: userId, or card's key, values: bitmap of cards condition.
# param:  totalsHashRef hash reference - of card names keyed by total items converted as value.
# return: hash reference of userKeys and total converted.
sub convertCards( $$ )
{
	my ( $cardsHashRef, $totalsHashRef ) = @_;
	my $totalItems = 0;
	while ( my ( $userKey, $bitMap ) = each( %$cardsHashRef ) )
	{
		if ( ( $bitMap & $C_RECOMMEND ) == $C_RECOMMEND )
		{
			# output all the valid item keys to file ready for APIServer command.
			my $converted = selectReportPrepareCardTransactions( $userKey );
			print "CONVERTED: $userKey\n" if ( $opt{'d'} );
			$totalsHashRef->{ $userKey } = $converted;
			$totalItems += $converted;
		}
	}
	return $totalItems;
}

# Selects items for conversion. This means that we look for items
# from the long-checked-out discard file.
# param:  cardHashRef hash reference - keys: userId, or card's key, values: bitmap of cards condition. 
# param:  totalsHashRef hash reference - of card names keyed by total items converted as value.
# return: hash reference of userKeys and total converted.
sub convertItems( $$ )
{
	my ( $cardsHashRef, $totalsHashRef ) = @_;
	my $totalItems = selectReportPrepareItemTransactions( $opt{'i'}, $totalsHashRef );
	if ( $opt{'d'} )
	{
		while ( my ( $userKey, $count) = each( %$totalsHashRef ) )
		{
			print "CONVERTED $count items from $userKey\n";
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
# param: bit flag for the item being reported.
# return: string containing report results.
sub reportStatus( $ )
{
    my ( $cardHashRef ) = shift;
	my ( $key, $bitMask);
	# my @convert = ();
	my @badName = ();
	my @overQuota = ();
	my @barred = ();
	my $status = "\nCard Status:\n------------\n";
	while ( ( $key, $bitMask ) = each( %$cardHashRef ) )
	{
		$bitMask = $cardHashRef->{ $key };
		# push( @convert, $key ) if (( $bitMask & $C_CONVERTED ) == $C_CONVERTED );
		push( @badName, $key ) if (( $bitMask & $C_MISNAMED ) == $C_MISNAMED );
		push( @overQuota, $key ) if (( $bitMask & $C_OVERLOADED ) == $C_OVERLOADED );
		push( @barred, $key ) if (( $bitMask & $C_BARRED ) == $C_BARRED );
	}
	# $status .= "converted: ".scalar( @convert )."\n@convert\n\n";
	$status .= "bad card: ".scalar( @badName )."\n@badName\n\n";
	$status .= "over quota: ".scalar( @overQuota )."\n@overQuota\n\n";
	$status .= "barred: ".scalar( @barred )."\n@barred\n\n";
	return $status;
}

################
# Main entry
init();

# create a new list if one doesn't exist yet.
resetDiscardList() if ( not -s $discardsFile );
my $cardHashRef    = validateCards();
my $convertHashRef = {};
my $totalItemsSoFar= 0;
my $totalCards     = scalar( keys %$cardHashRef );
# card scanning sets bitmask including any convert recommendations.
my $cardsDone      = scanDiscardCards( $cardHashRef, $totalItemsSoFar );
# if all the cards have been handled, its time to back it up and create a new one.
if ( $cardsDone >= $totalCards )
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
}
# Start the conversion process if requested.
if ( $opt{'c'} )
{
	# cleanup files that are dangerous to have around: $requestFile, $tmpFileName.
	# request will have API commands which we don't run twice and tmpFileName will contain
	# item keys from another process.
	unlink( $requestFile ) if ( -s $requestFile );
	unlink( $tmpFileName ) if ( -s $tmpFileName );
	# if we are doing item-centric discards start here.
	if ( $opt{'i'} )
	{
		$totalItemsSoFar = convertItems( $cardHashRef, $convertHashRef );
		updateResults( $convertHashRef );
	}
	else # start here for card-centric discards.
	{
		while ( $totalItemsSoFar <= $targetDiscardItemCount )
		{
			my $converted = convertCards( $cardHashRef, $convertHashRef );
			$totalItemsSoFar += $converted;
			updateResults( $convertHashRef );
			# rescan the list for changes. This will clear the recommended cards provide a recount of converted.
			$cardsDone = scanDiscardCards( $cardHashRef, $totalItemsSoFar );
			# stop if we have finished the list or remaining selections are disqualified.
			last if ( $cardsDone == $totalCards or $converted == 0 );
		}
	}
	# run the apiserver with the commands to convert the discards.
	`apiserver -h <$requestFile >>$responseFile` if ( -s $requestFile );
}

my $report = showReports( $totalItemsSoFar );
print "$report\n";
mail( "Discard Report", $opt{'m'}, $report ) if ( $opt{'m'} );
# remove the list of long-checked-out items so they don't get processed again tomorrow.
unlink( $opt{'i'} ) if ( $opt{'i'} );
