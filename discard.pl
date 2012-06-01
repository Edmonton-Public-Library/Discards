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
# Rev:     0.0 - develop
#
#
########################################################################

use strict;
use warnings;
use vars qw/ %opt /;
use Getopt::Std;
# Use this for writing files to EPLAPP.
use Fcntl;          # Needed for sysopen flags O_WRONLY etc.
# See Unicorn/Bin/mailfile.pl <subject> <file> <recipients> for correct mailing procedure.

my $targetDicardItemCount = 2000;
# This value is used needed because not all converted items get discarded.
my $fudgeFactor           = 0.1;  # percentage of items permitted over target limit.
my $mail                  = "";   # mail content.
my %holdsCards;                   # list of cards that have holds on them
my %overLoadedCards;              # cards that exceed the convert limit set with -n
my %barCards;                     # List of cards that exceed 1000 items currently.
my %okCards;                      # List of cards whose's status is OK (not BARRED).
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

usage: $0 [-xcrecq] [-n number_items] [-m email]

 -c        : Convert the recommended cards automatically.
 -e        : write the current finished discard list to MS excel format.
             default name is 'Discard[yyyymmdd].xls'.
 -m "addrs": mail output to provided address
 -n        : sets the upper limit of the number of discards to process.
 -q        : quiet mode, just print out the recommended cards. Email will still
             contain all stats.
 -r        : reset the list. Re-reads all discard cards and creates a new list.
             other flags have no effect.
 -x        : this (help) message

example: $0 -ecq -n 1500 -m anisbet\@epl.ca

EOF
    exit;
}

# Kicks off the setting of various switches.
# param:
# return:
sub init()
{
    my $opt_string = 'rm:n:xecq';
    getopts( "$opt_string", \%opt ) or usage();
    usage() if ($opt{x});                            # User needs help
    $targetDicardItemCount = $opt{'n'} if ($opt{n}); # User set n
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
    if ($status eq "OK")
    {
        $okCards{substr($id,0,3)} += 1;
    }
    if ($itemCount > $targetDicardItemCount)
    {
        $overLoadedCards{$id} = "$description|$dateCreated|$dateUsed|$itemCount|$holds|$bills|$status Item Count = $itemCount";
    }
    if ($itemCount <= $targetDicardItemCount and $dateConverted == 0)
    {
        if ($itemCount + $runningTotal <= $targetDicardItemCount)
        {
            # update the running total
            $runningTotal += $itemCount;
			# if convert not selected we will get the same recommendations tomorrow.
			if ($opt{c})
			{
				my $updatedRecord = convertDiscards($_);
				if ($updatedRecord ne "") # if conversion successful.
				{
					# update all the variables.
					($id, $userKey, $description, $dateCreated, $dateUsed, $itemCount, $holds, $bills, $status, $dateConverted, $converted) = split('\|', $updatedRecord);
					$dateConverted = $today;
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

if (!$opt{q})
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
if ($opt{m})
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
if ($opt{e})
{
    sysopen(CARDS, $discardsFile, O_RDONLY) ||
        die "Couldn't read '$discardsFile' because of failure: $!\n";
    open(EXCEL, "| excel.pl -t 'Patron ID|Name|Created|L.A.D|No. of Charges|No. of Converts|' -o Discards$today.xls")
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


# These functions perform the conversion if -c is used on the command line.
# param: DISCARD record as: WOO-DISCARDCA5|659264|WOO-XXX DISCARD CAT ITEMS|20100112|20120430|581|0|0|BARRED|00000000|0|
# return: String record as: WOO-DISCARDCA5|659264|WOO-XXX DISCARD CAT ITEMS|20100112|20120430|581|0|0|BARRED|20120510|500|
#         or an empty string on failure.
sub convertDiscards
{
	my $card = @_;
	my $status = 0;
	print "CONVERTING: $card\n";
	return "";
	# The process of conversion does the following:
	# discharge items from the users of profile DISCARD.
	# Discharge items charged by intra-library loan - N/A
	# Changes the current location of the item to DISCARD.
	#
	# Items are disqualified if they have:
	# ** bills
	# ** one or more copy level holds
	# Items is on order - N/A
	# Item is under serial control - N/A
	# Item is accountable - N/A
	#
	# Sirsi does this via these commands:
	# doCommand("seluser",
			  # "-iB -c\"\>0\" -oK", 
			  # $TempFiles{'dat'}, 
			  # $TempFiles{'userKeys'},
			  # $TempFiles{'c'},
			  # \$Directives{'status'});
	
	# doCommand("selcharge",
			  # "-iU -oIy $Directives{'selchargeoptions'}", 
			  # $TempFiles{'userKeys'},
			  # $TempFiles{'chargeKeys'},
			  # $TempFiles{'d'},
			  # \$Directives{'status'});
			  
	# doCommand("selitem",
            # "-iI -oNBS $Directives{'selitemoptions'}", 
            # $TempFiles{'chargeKeys'},
            # $TempFiles{'itemKeys'},
            # $TempFiles{'e'},
            # \$Directives{'status'});
			  
	# doCommand("selcallnum",
			  # "-iN -oCS $Directives{'selcallnumoptions'}", 
			  # $TempFiles{'itemKeys'},
			  # $TempFiles{'callnumKeys'},
			  # $TempFiles{'g'},
			  # \$Directives{'status'});
			  
	# doCommand("selcatalog",
			# "-iC -oS $Directives{'selcatalogoptions'}", 
			# $TempFiles{'callnumKeys'},
			# $TempFiles{'items'},
			# $TempFiles{'h'},
			# \$Directives{'status'});
			  
	# Update_toDiscard();
    
    # #requested update of database records
	# #sets up a log of the errors from the process we want this.
    # doCommand("apiserver",
              # "-h -e$errlogdir", 
              # $TempFiles{'trans'},
              # $TempFiles{'trans_response'},
              # $TempFiles{'k'},
              # \$Directives{'status'});

    # #Error messages from failed discharge transactions are found in the file
    # PrintMessage("\$(14286)","$TempFiles{'k'}");
    # system("sirsiecho \"$errlogdir/$Directives{'today_date'}.error\" >>$TempFiles{'k'}");

    # if ($Directives{'status'} == 0)
      # {
      # doCommand("selitem",
                # "-iB -c0", 
                # $TempFiles{'items'},
                # $TempFiles{'keys'},
                # $TempFiles{'l'},
                # \$Directives{'status'});

      # #Capture item keys at selitem since edititem does not output keys
      # doCommand("edititem",
                # "-8\"$Directives{'operatordata0'}|$Directives{'stationdata0'}\" -m\"DISCARD\"", 
                # $TempFiles{'keys'},
                # $TempFiles{'m'},
                # $TempFiles{'n'},
                # \$Directives{'status'});

      # if ($Directives{'status'} == 0)
        # {
        # chdir($textedit);
        # CreateCatKeyFiles($TempFiles{'keys'});

        # if ($browse_heading != 0) 
          # {
          # chdir($browsedit);
          # CreateCatKeyFiles($TempFiles{'keys'});
          # }
        # }
      # }
    # }
}

# sub Update_toDiscard()
# {
  # my $date;
  # my $station;
  # my $uacs;

  # chomp($uacs = `sirsiecho $Directives{'operatordata0'} | seluser -iB -oP 2>$TempFiles{'j'}`);
  # chomp($date = `transdate -d-0 -h`);
  # $uacs =~ s/\|$//;
  # $station = "001";

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
# }




