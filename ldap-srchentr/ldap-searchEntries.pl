#!/usr/bin/perl
#############################################################################
#  Search for Entries with variable filter                                  #
#  Version: 0.9                                                             #
#  Author:  Benedikt Hallinger <beni@hallinger.org>                         #
#                                                                           #
#  This program searches for entries based on a list provided by STDIN.     #
#  The values given from STDIN are parsed into a filterstring containing    #
#  placeholders. The found DNs are returned for each search.                #
#                                                                           #
#  Please not that for each line in STDIN one search is performded,         #
#  this may cause load on the server but at least takes some time.          #
#  Try to use indexed attributes when ever possible.                        #
#                                                                           #
#  Errors and verbose inforamtion are printed to STDERR.                    #
#  The exported data is usually in UTF8 but will be print like it is        #
#  fetched from the directory server. You can use 'recode' to convert.      #
#  The human readable format is easily parseable to LDIF format via         #
#  standard shell commands.                                                 #
#                                                                           #
#  Please call 'ldap-searchEntries.pl -h' for available command line        #
#  options and additional information.                                      #
#                                                                           #
#  Exit codes are as following:                                             #
#    0 = all ok                                                             #
#    1 = connection or bind error                                           #
#    2 = operational error                                                  #
#                                                                           #
#  Required modules are                                                     #
#    Net::LDAP                                                              #
#    Net::LDAP::Control::Paged                                              #
#    Net::LDAP::Constant                                                    #
#    Getopt::Std                                                            #
#  You can get these modules from your linux package system or from CPAN.   #
#                                                                           #
#############################################################################
#  This program is free software; you can redistribute it and/or modify     #
#  it under the terms of the GNU General Public License as published by     #
#  the Free Software Foundation; either version 2 of the License, or        #
#  (at your option) any later version.                                      #
#                                                                           #
#  This program is distributed in the hope that it will be useful,          #
#  but WITHOUT ANY WARRANTY; without even the implied warranty of           #
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the            #
#  GNU General Public License for more details.                             #
#                                                                           #
#  You should have received a copy of the GNU General Public License        #
#  along with this program; if not, write to the Free Software              #
#  Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111, USA.   #
#############################################################################

use strict;
use Net::LDAP;
use Net::LDAP::Control::Paged;
use Net::LDAP::Constant qw( LDAP_CONTROL_PAGED );
use Getopt::Std;

my $time_start = time; # for stats afterwards

#
# Parsing CMDline options
#
# Default values (and var assingment)
my $host        = 'localhost';
my $searchbase  = '';
my $user        = '';
my $pass        = '';
my $filter      = "";
my $verbose     = 0;
my $singleval   = 0;
my $scope       = 'sub';
my $sep         = '\s';
my @attributes  = (1.1);  # don't query attrs
my $csv         = 0;

# Mask password parameter if given, so it wont show at process list
my $cmdname = $0;
my $cmdline = "$0";
my $lo = "";
foreach my $o (@ARGV) {
	if ($lo eq "-p") {
		$cmdline = "$cmdline ***";
	} else {
		$cmdline = "$cmdline $o";
	}
	$lo = $o;
}
$0 = $cmdline;

# Use Getopt to parse cmdline
my %Options;
my $arg_count = @ARGV;
my $arg_ok = getopts('a:chvu:p:b:H:f:i:s:S:', \%Options);
if ($Options{h}) {
	usage();
	help();
	exit 0;
}
if (!$arg_ok) {
	usage();
	exit 2;
}

if ($Options{H} =~ /^(ldap[si]?:\/\/.+?)\/(.+)/i) {
	# Support for LDAP-URL: It takes precedence over parameters on command line.
        $host = $1;
        my @queryspec = split(/\?/, $2);
        if (defined $queryspec[0]) {$Options{b} = $queryspec[0];}
	if (defined $queryspec[1] && $queryspec[1] ne "") {$Options{a} = $queryspec[1];}
        if (defined $queryspec[2] && $queryspec[2] ne "") {$Options{S} = $queryspec[2];}
        if (defined $queryspec[3] && $queryspec[3] ne "") {$Options{f} = $queryspec[3];}
} else {
	# no LDAP URL detected: was the host given in plain?
	if ($Options{H}) {$host = $Options{H};}
}

# set and verify options
if ($Options{'a'}){
	@attributes = split(/\s|,|\\;/, $Options{'a'});
}
if ($Options{'S'}){
	if ($Options{'S'} =~ /^base|one|sub$/) {
		$scope = $Options{'S'};
	} else {
		print STDERR "-S must be one of 'base', 'one' or 'sub'.\n";
		exit 2;
	}
}
if ($Options{i}) {
	my $infile = $Options{i};
	open(INFILE, '<', $infile) or die("Unable to open $infile\n");
} else {
	open(INFILE, '-') or die("Unable to open STDIN\n");
}
if (defined($Options{'p'})){ $pass       = $Options{'p'};}
if ($Options{'H'}){ $host                = $Options{'H'};}
if (defined($Options{'b'})){ $searchbase = $Options{'b'};}
if ($Options{'v'}){ $verbose             = 1;}
if ($Options{'f'}){ $filter              = $Options{'f'};}
if (defined($Options{'s'})){ $sep        = $Options{'s'};}
if (defined($Options{'c'})){ $csv        = 1;}

# check for missing mandatory parameters
foreach my $o ('b', 'f') {
	if ( !defined($Options{$o}) ) {
		print STDERR "Parameter -$o is mandatory!\n";
		usage();
		exit 2;
	}
}

# Get credentials if authenticated bind was requested
if ($Options{'u'}){
	if (!$Options{p}) {
		if (-t STDIN) {
			# ask user interactively for password
			print STDERR "LDAP password: ";
			system('stty','-echo');
			chomp($pass=<STDIN>);
			system('stty','echo');
			print STDERR "***\n";
		} else {
			# no tty: just grab from STDIN
			chomp($pass=<STDIN>);
		}
	}
	$user = $Options{'u'};
}


#
# Connect and bind to server
#
if ($verbose) { print STDERR "connecting to $host...\n"; }
my $ldap = Net::LDAP->new($host);   # LDAP-Verbindung aufbauen
if (!$ldap){
	print STDERR "Could not connect to $host!\n(Server says: $@)\n\n";
	exit 1;
}
if ($user) {
	my $mesg = $ldap->bind($user, 'password' => $pass);
	if($mesg->code){
		print STDERR "Authentication failed!\n(Server says: ".$mesg->error.")\n\n";
		exit 1;
	}
} else {
	my $mesg = $ldap->bind();
}


# set helper variables
my $csv_header_printed = 0;
my $totalcount = 0;
my $totalmatch = 0;
if ($verbose) {print STDERR "reading from STDIN\n";}

# print CSV Header in CSV-mode
my $selAttrsCount = 0;
if ($csv) {
	print "\"Args\";\"# of found entries\""; # print CSV Header 
	foreach my $a (@attributes) {
		$a == "1.1" && next;  # skip 1.1
		print ";\"$a\"";
		$selAttrsCount++;
	}
	print "\n";
}

while (my $searchvalues = <INFILE>) {
	#
	# Build dynamic filter based on STDIN splitting
	#
	chomp($searchvalues);
	my $sv_count = () = $filter =~ /%\d+|(?:\{%|%\{)\d+}/g; # count all "%n"s in the filter so we can create error output
	my @splitvals = split /$sep/, $searchvalues; # split STDIN into fields
	if ($verbose) { print STDERR "csv splitresult: ".scalar(@splitvals)." fields; detected $sv_count placeholders in filter\n";}

	# parse the fields into the filter
	my $filter_parsed = $filter;
	for (my $i = scalar(@splitvals); $i > 0; $i--) {
		my $cur_val = $splitvals[$i-1];
		$filter_parsed =~ s/%$i(?!\d)|(?:\{%|%\{)$i}/$cur_val/g;
		if ($verbose) { print STDERR "filter parsing {%$i} => '$cur_val'\n";}
	}

	# print a warning if placeholders did not get filled
	my @failedPlaceholders   = $filter_parsed =~ /(%\d+|(?:\{%|%\{)\d+})/g;
	my $failedPlaceholders_c = scalar(@failedPlaceholders);
	if ($failedPlaceholders_c > 0) {
		print STDERR "WARNING: line $. is missing $failedPlaceholders_c referenced fields (".join(',', @failedPlaceholders).")!\n";
	}

	# build searchargs
	my @searchArgs = (
        	base    => $searchbase,
		filter  => $filter_parsed,
		attrs   => \@attributes,
		scope   => $scope
	);

	#
	# Perform search and print data
	#
	if ($verbose) { print STDERR "performing search (@searchArgs)... "; }

	my $mesg = $ldap->search(@searchArgs);
	if ($mesg->code) {
		print STDERR "LDAP search failed!\n(Server says: ".$mesg->error."\n\n";
		exit 2;
	} else {
		 if ($verbose) { print STDERR "OK \n";}

		# collect data
		my $s_count = $mesg->count();
		my @entries = $mesg->entries();
		if ($mesg->count() > 0) {
			$totalmatch++;
			$totalcount += $s_count;
		}

		if ($csv) {
			# CSV-Mode

			# append selected attributes
			if ($selAttrsCount > 0) {
				# attributes selected: print csv record for every found entry
				if ($s_count == 0){
        	                        # no entries found
					print "\"$searchvalues\";\"$s_count\"\n";
                	        } else {
                        	        # entries matched filter
                                	while (my $entry = shift(@entries)) {
						print "\"$searchvalues\";\"$s_count\"";

	                                        # if attribute list is not "1.1", then list attributes
        	                                foreach my $a (@attributes) {
                	                                $a == "1.1" && next;  # skip 1.1
                        	                        my $attr    = $entry->get_value($a, 'asref' => 1);
                                	                if (!defined($attr)) {
								print ";\"\"";
								next;
	                                                }
        	                                        my @values  = @$attr;
                	                                foreach my $val (@values) {
                        	                                print ";\"$val\"";
                                	                }
                                        	}
						print "\n";
        	                        }
                        	}

			} else {
				# just print match count
				print "\"$searchvalues\";\"$s_count\"\n";
			}

		} else {
			# normal human readable format: number and matched DNs
			print "$searchvalues: $s_count entries found";
			if ($mesg->count() == 0){
				# no entries found
				print ".\n";
			} else {
				# entries matched filter
				print ":\n";
				while (my $entry = shift(@entries)) {
					print "  ".$entry->dn."\n";
					
					# if attribute list is not "1.1", then list attributes
					foreach my $a (@attributes) {
						$a == "1.1" && next;  # skip 1.1
						my $attr    = $entry->get_value($a, 'asref' => 1);
						if (!defined($attr)) {
							# attribute empty or not defined
							next;
						}
						my @values  = @$attr;
						foreach my $val (@values) {
							print "    $a: $val\n";
						}
					}
				}
				print "\n";
			}
		}
	}
}

# all fine, go home
$ldap->unbind();
$ldap->disconnect();
if ($verbose) {
	print STDERR "A total of $totalcount entries were found.\n";
	print STDERR "A total of $totalmatch filters matched.\n";
	my $runtime = time - $time_start;
	print STDERR "done in $runtime s\n"
}
exit 0;


# Usage information for help screen
sub usage {
	print "Search for entries with a variable filter, provided by STDIN.\n";
	print "Synopsis:\n";
	print "  ./ldap-searchEntries.pl -b searchbase -f filter \n";
	print "                      [-H Host|URL] [-u user-dn] [-p pwd] [-i infile] [-v]\n";
	print "  ./ldap-searchEntries.pl -h\n";
	print "\nMandatory options:\n";
	print "  -b  LDAP searchbase\n";
	print "  -f  LDAP filter with Placeholders. Placeholders are strings with the format '%n':\n";
	print "      The input string provided by STDIN is split by parameter -s and then fed\n";
	print "      into the searchfilter replacing the %n occurences, where 'n' denotes a\n";
	print "      field number which tells what file value should go where in the filter.\n";
	print "      If you need to use a placeholder followed by numbers, you can enclose the\n";
	print "      placeholder in curly brackets: '%{2}1234'.\n";
	print "      If STDIN provides less fields than referenced placeholders, the placeholder\n";
	print "      remains unset and a warning message is written to STDERR.\n";
	print "\nOptional options:\n";
	print "  -a  Attribute list specifiying the attributes to print for each found entry. Attributes\n";
	print "      are to be separated by space, commata or escaped semicolon (\"\\;\").\n";	
	print "  -c  Enable CSV mode: just print the filter match result in CVS-format and suppress DN printing.\n";
	print "      Selected attributes will be appended to the result line (first value only).\n";
	print "  -i  Input file to read filter args from (in case you dont want to use STDIN or redirection).\n";
	print "  -h  Show more help than this usage information\n";
	print "  -H  LDAP server to contact (default: '$host')\n";
	print "      The basic form is [hostname|IP(:port)] like '127.0.0.1' or 'localhost:9389'.\n";
        print "      If ports are not specified, defaults will be used (389 ldap, 636 ldaps).\n";
        print "      Alternative URL: [<scheme>://<host(:port)>(/<baseDN>(?<attrs>(?<scope>(?<filter>))))]\n";
        print "      The optional items baseDN, attrs, scope and filter will override cmdline options.\n";
        print "      Example: 'ldaps://ldap.org:333/cn=base,o=ldap,dc=org?cn,mail?sub?(sn=\%1)'\n";
	print "  -p  Password of user for binding (see -u; will ask if omitted)\n";
	print "  -s  regexp for separating STDIN values (default: '$sep')\n";
	print "  -S  Scope of LDAP search (default: '$scope')\n";
	print "  -u  DN of user for binding (anonymous if not given)\n";
	print "  -v  Show at STDERR what the program does\n";
}

# Prints extendet help
sub help {
	print "\n\nAdditional information:\n";
	print "  Exit codes are as following:\n";
	print "    0 = everything was ok\n";
	print "    1 = connection or bind error\n";
	print "    2 = operational error\n";
	print "\nA word on the -a parameter with semicolon\n";
	print "    The semicolon MUST be escaped to be used as attribute\n";
	print "    selection separator, because LDAP allows \"attribute flavors\":\n";
	print "      -a 'sn,givenName,description;lang-en'  => sn, givenName, description;lang-en\n";
	print "      -a 'sn,givenName,description\\;lang-en' => sn, givenName, description, lang-en\n";
	print "\nExample (-H, -u and -p are omitted):\n";
	print "    Imagine your boss comes around with the following issue:\n";
	print "      Boss: \"I have a list for you. Please give me information, wheter each AD account\n";
	print "              is existing and i want the telephoneNumber of each existing account.\"\n";
	print "      You: No problem, you have it in a few minutes.\n";
	print "      The List is a CSV file export from SAP consisting of several fields. For us, only\n";
	print "      the name fields are relevant, which is stored in field 2 and 3:\n";
	print "        ----users.csv----\n";
	print "        23453;John;Doe;1;Mr\n";
	print "        43432;Mike;Johnson;1;Mr\n";
	print "        68855;Melinda;Jones;2;Mrs\n";
	print "        [a whole lot more lines]\n";
	print "        ----users.csv----\n";
	print "      The one liner to make things happen is just:\n";
	print "        ldap-searchEntries.pl -b dc=example,dc=com -s ';' -a telephoneNumber \\\n";
	print "                -f '(&(objectclass=user)(givenName=%2)(sn=%3))' \\\n";
	print "                 < users.csv > result.txt\n";
	print "      The -a parameter selects the telephoneNumber attribut for output.\n";
	print "      The -s parameter is used to split the files records into fields that are then assigned\n";
	print "      to the %-placeholders in our filter. The filter selects \"user\" objects that have the\n";
	print "      first and last name (our friendly AD-Administrator told us, this is safe). Note that the\n";
	print "      filters placeholders start with 2, not with 1, since we want to select the second field.\n";
	print "      The constructed filter is then used to search the directory. Voila!\n";
	print "      The output piped to result.txt is something like:\n";
	print "        ----result.txt----\n";
	print "        23453;John;Doe;1;Mr: 1 entries found:\n";
	print "          cn=john.doe,ou=users,dc=example,dc=com\n";
	print "            telephoneNumber: 01234 567890-123\n";
	print "        \n";
	print "        43432;Mike;Johnson;1;Mr: 0 entries found.\n";
	print "        [a whole lot of more lines]\n";
	print "        ----result.txt----\n";
	print "\nKeep the LDAP password secure:\n";
	print "  If you use the -p parameter to supply a password, the program will mask it so it\n";
	print "  will not show on the process list. However, this is still not entirely secure. If\n";
	print "  run interactively, you should type in the password (just omit -p) or pass it by\n";
	print "  reading it from file (e.g. 'cat passwordFile | $cmdname ...').\n";
	print "  Be sure to keep the file secure (proper access rights etc).\n";
	print "\nTroubleshooting:\n";
	print "  If you have problems with special characters (e.g. german umlauts),\n";
	print "  use the program 'recode' to change the encoding of the resulting file.\n";
	print "  LDAP servers usually serve their data in utf-8. To make the output MS-Excel friendly,\n";
	print "  do: '$cmdname ... | recode utf8..latin1'.\n\n";
	print "  In case you get weird output, check the file line ending format. This can be an issue\n";
	print "  when consuming csv files from windows on a linux system (especially with smb mounts).\n";
	print "\n  If you find bugs, please report them to the bugtracker:\n";
        print "    https://github.com/hbeni/ldap-tools/issues\n";
}
