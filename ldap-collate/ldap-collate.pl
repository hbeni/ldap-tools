#!/usr/bin/perl
#############################################################################
#  Collate and count LDAP entries based on an attribute                     #
#  Version: 0.1                                                             #
#  Author:  Benedikt Hallinger <beni@hallinger.org>                         #
#                                                                           #
#  This program allows you to easily collate and count entries by selecting #
#  an attribute. Entries are searched and then grouped by attribute         #
#  occurrence, which is then printed as result.                             #
#                                                                           #
#  Errors and verbose inforamtion are printed to STDERR.                    #
#  The exported data is usually in UTF8 but will be print like it is        #
#  fetched from the directory server. You can use 'recode' to convert.      #
#                                                                           #
#  Please call 'ldap-collate.pl -h' for available command line              #
#  options and additional information.                                      #
#                                                                           #
#  Exit codes are as following:                                             #
#    0 = all ok                                                             #
#    1 = connection or bind error                                           #
#    2 = operational error                                                  #
#    3 = LDAP paging error                                                  #
#    4 = LDAP sorting error                                                 #
#                                                                           #
#  Required modules are                                                     #
#    Net::LDAP                                                              #
#    Net::LDAP::Control::Paged                                              #
#    Net::LDAP::Control::Sort                                               #
#    Net::LDAP::Constant                                                    #
#    Getopt::Std                                                            #
#  You can get these modules from your linux package system or from CPAN.   #
#                                                                           #
#  Hosted at: https://github.com/hbeni/ldap-tools/                          #
#  Please report bugs and suggestions using the trackers there.             #
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
use Switch;
use Net::LDAP;
use Net::LDAP::Util;
use Net::LDAP::Control::Paged;
use Net::LDAP::Control::Sort;
use Net::LDAP::Constant qw( LDAP_CONTROL_PAGED LDAP_CONTROL_SORTRESULT );
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
my @attributes  = ();
my $filter      = "(objectclass=*)";
my $mvsep       = "|";
my $fieldquot   = '"';
my $fieldsep    = ";";
my $verbose     = 0;
my $singleval   = 0;
my $pagesize    = 100;
my $scope       = 'sub';
my $timelimit   = 0;
my $sizelimit   = 0;
my $sortorder   = '';
my $contimeout  = 240;
my $re_dnfilter = "";
my $print_elem  = 0;  # print elements isntead of count


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
my $arg_ok = getopts('c:ha:eu:vp:b:H:f:F:m:q:S:s:l:o:t:T:', \%Options);
if ($Options{h}) {
	usage();
	help();
	exit 0;
}
if (!$arg_ok) {
	print STDERR "Options error!\n";
	usage();
	exit 1;
}

# set and verify options
if (defined($Options{'p'})){ $pass       = $Options{'p'};}
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

if (defined($Options{'b'})){ $searchbase = $Options{'b'};}
if ($Options{'v'}){ $verbose             = 1;}
if ($Options{'f'}){ $filter              = $Options{'f'};}
if (defined($Options{'m'})){
	$mvsep     = $Options{'m'};
	$mvsep     =~ s/((?<!\\)\\[tsrn])/"qq{$1}"/gee; # support \n and some of its friends
	$mvsep     =~ s/\\\\/\\/g;
}
if (defined($Options{'q'})){
	$fieldquot = $Options{'q'};
	$fieldquot =~ s/((?<!\\)\\[tsrn])/"qq{$1}"/gee; # support \n and some of its friends
	$fieldquot =~ s/\\\\/\\/g;
}
if (defined($Options{'s'})){
	$fieldsep  = $Options{'s'};
	$fieldsep  =~ s/((?<!\\)\\[tsrn])/"qq{$1}"/gee; # support \n and some of its friends
	$fieldsep  =~ s/\\\\/\\/g;
}
if (defined($Options{'l'})){ $pagesize   = $Options{'l'};}
if (defined($Options{'t'})){ $contimeout = $Options{'t'};}
if (defined($Options{'T'})){ $timelimit  = $Options{'T'};}
if (defined($Options{'o'})){ $sortorder  = $Options{'o'};}
if (defined($Options{'c'})){ $sizelimit  = $Options{'c'};}
if (defined($Options{'a'})){
	@attributes = split(/(?<!\\)\s|(?<!\\),|(?<!\\);/, $Options{'a'});

	my $cnt = @attributes;
	if ($cnt != 1) {
		# TODO: Implement me please
		print STDERR "-a with more than one attribute is not yet supported. Sorry!\n";
                exit 1;
	}
}
if (defined($Options{'e'})){ $print_elem = 1;}

if ($Options{'S'}) {
	if ($Options{'S'} =~ /^base|one|sub$/) {
		$scope = $Options{'S'};
	} else {
		print STDERR "-S must be one of 'base', 'one' or 'sub'.\n";
		exit 1;
	}
}
if ($Options{'F'}){
	if ($Options{'F'} !~ /^\/(.*)\/(?:[gismoxe])*$/) {
		print STDERR "-F must be a valid regular expression ('/<pattern>/').\n";
                exit 1;
	}
	$re_dnfilter         = $Options{'F'};
}

# check for missing mandatory parameters
foreach my $o ('a', 'b') {
	if ( !defined($Options{$o}) ) {
		print STDERR "Parameter -$o is mandatory!\n";
		usage();
		exit 1;
	}
}
if ($Options{'u'}) {
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
my $ldap = Net::LDAP->new($host, timeout => $contimeout);   # LDAP-Verbindung aufbauen
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


#
# Set up CONTROLs for the search
#
my $page = Net::LDAP::Control::Paged->new( size => $pagesize );
my $cookie = undef;
my @controls = ($page);
if ($sortorder ne '') {
	my $order = Net::LDAP::Control::Sort->new( order => $sortorder );
	push(@controls, $order);
}
my @searchArgs = (
	base      => $searchbase, 
	filter    => $filter, 
	scope     => $scope,
	attrs     => \@attributes,
	sizelimit => $sizelimit,
	timelimit => $timelimit,
	control   => \@controls
);


# set helper variables
my $exitVal = undef;
my $totalcount = 0;
my $lastPage = 0;
my %results;    # results has: key is the attribute value and values are the matched entries DNs

do {
	#
	# Perform search and print data
	#
	if ($verbose) { print STDERR "performing search (filter='$filter'; searchbase='$searchbase')... "; }
	my $mesg = $ldap->search(@searchArgs);
	if ($mesg->code) {
		# handle error codes differently, as some codes arent merely errors.
		my $errortext = $mesg->error();
		my $errorcode = $mesg->code();
		my $errorname = $mesg->error_name();

		switch ($errorcode) {
			case [3,4] {
				# timelimit/sizelimit exceeded - partial results, but OK
				print STDERR "INFO: $errortext\n";
			}
			else {
				print STDERR "LDAP ERROR $errorcode ($errorname): $errortext\n";
				$exitVal = 2;
			}

		}

	}
	if (!defined($cookie) && $mesg->count() == 0){
		print STDERR "No entries found. Check searchparameters.\n";
		$exitVal = 0;
	} else {
		if ($verbose) { print STDERR $mesg->count()." entries found.\n"; }
		$totalcount += $mesg->count();
		# search was ok
		
		# get control element for paged result set and save it to the cookie
		# (in case paging is not supported, $response is undef)
		my($response) = $mesg->control( LDAP_CONTROL_PAGED ) or $exitVal = 3;
		if (defined($response)) {
			$cookie = $response->cookie or $exitVal = 3;
			if ($exitVal eq 3) {
				$lastPage = 1; # process the last page
			}
                } else {
			# No proper paging support. Single page will be processed instead.
			$exitVal = 0;
			$lastPage = 1;
                }

		my ($sortresponse) = $mesg->control( LDAP_CONTROL_SORTRESULT );
		if($sortresponse) {
			if ($sortresponse->result) {
				print STDERR "sorting not possible, LDAP-error ".$sortresponse->result.". Returning unsorted results\n";
				if ($Options{'o'}) {
					# In case sorting is explicitely needed, exit
					$exitVal = 4;
				}
			}
		}
		if (!defined($exitVal) || $lastPage){
			# Now dump all found entries for the page
			if ($verbose) { print STDERR "processing page: $lastPage\n"; }
			while (my $entry = $mesg->shift_entry()){
				if ($re_dnfilter) {
					my $evalRC = eval("\$entry->dn() =~ $re_dnfilter;"); # eval regexp (eval needed to have re-options available and full re support)
					if ($evalRC) {
						if ($verbose) { print STDERR "ignored entry (-F matched): ".$entry->dn()."\n"; }
						next;
					}
				}

				# sort the DN into the results hash for the attribute
				# thereby resolve multivalued attributes
				# TODO: Implement support for multiple attributes by generating a cross product
				foreach my $curattr (@attributes) {
					foreach my $val ($entry->get_value($curattr)) {
						if ($verbose) { print STDERR "  [$val] => ".$entry->dn()."\n"; }
						push (@{$results{$val} }, $entry->dn());
					}
				}
			}
			if ($verbose) { print STDERR "\n"; }
			# get cookie of the servers response
			$page->cookie($cookie);
			$lastPage = 0;
		}
	}
} until (defined($exitVal));


#
# Print results
#
foreach my $attrval ( keys %results ) {
	my @entries = @{ $results{$attrval} };
	my $rs; # results string
	if ($print_elem) {
		$rs = join($mvsep, @entries);
	} else {
		$rs = @entries;  # count array elements
	}

	print "$fieldquot$attrval$fieldquot$fieldsep$fieldquot$rs$fieldquot\n";
}




if ($verbose) { print STDERR "A total of $totalcount entries were found\n"; }

if( defined( $cookie ) ){
	$page->cookie($cookie);
	$page->size(0);
	$ldap->search(@searchArgs);
}


#
# all fine, go home
#
$ldap->unbind();
$ldap->disconnect();
if ($verbose) {
	my $runtime = time - $time_start;
	print STDERR "done in $runtime s\n"
}
exit $exitVal;





# Usage information for help screen
sub usage {
	print "Collate and count LDAP entries\n";
	print "Synopsis:\n";
	print "  ./ldap-collate.pl -a attrlist [-H Host|URL] -b searchbase [-t timeout]\n";
	print "                      [-e] [-m mv-sep] [-q quotechar] [-s field-sep]\n";
	print "                      [-u user-dn] [-p password] [-f filter] [-F pattern]\n";
	print "                      [-o sortoptions] [-c sizelimit] [-T timelimit] [-v]\n";
	print "  ./ldap-collate.pl -h\n";
	print "\nMandatory options:\n";
	print "  -a  Attribute name(s) for collating. Separate multiple attrs with comma, space or semicolon.\n";
	print "  -b  LDAP searchbase\n";
	print "\nOptional options:\n";
	print "  -c  Sizelimit for LDAP-Search (default: unlimited)\n";
	print "  -e  Print found DNs instead of count number\n";
	print "  -f  LDAP filter (default: '$filter')\n";
	print "  -F  Regular expression ('/<pattern>/<option>') to filter entries by DN. DNs matching\n";
	print "      the pattern will be skipped and not printed to CSV output (default: skip none).\n";
	print "  -h  Show more help than this usage information\n";
	print "  -H  LDAP server to contact (default: '$host')\n";
	print "      The basic form is [hostname|IP(:port)] like '127.0.0.1' or 'localhost:9389'.\n";
        print "      If ports are not specified, defaults will be used (389 ldap, 636 ldaps).\n";
        print "      Alternative URL: [<scheme>://<host(:port)>(/<baseDN>(?<attr>(?<scope>(?<filter>))))]\n";
        print "      The optional items baseDN, attr, scope and filter will override cmdline options.\n";
        print "      Example: 'ldaps://ldap.org:333/cn=base,o=ldap,dc=org?sn?sub?(sn=Hall*)'\n";
	print "  -l  LDAP page size limit (default: '$pagesize', depends on your server)\n";
	print "  -m  String that is used to separate multiple found entries (default: '$mvsep')\n";
	print "  -o  Sorting rules: '[order]<attribute>[:rule] ...' (default: unsorted)\n";
	print "      (see extended help (-h) for the rules and examples)\n";
	print "  -p  Password of user for binding (see -u; will ask if omitted)\n";
	print "  -q  String that is used to quote entire csv fields (default: '$fieldquot')\n";
	print "  -s  String that separates csv-fields (default: '$fieldsep')\n";
	print "  -S  Scope of LDAP search (default: '$scope')\n";
	print "  -t  Timeout for connection to LDAP server (default: '$contimeout' seconds)\n";
	print "  -T  Timelimit for LDAP search (default: unlimited)\n";
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
	print "    3 = LDAP paging error\n";
	print "    4 = LDAP sorting error\n";
	print "\n\nUsing an attribute list with -a:\n";
	print "    You can provide an attribute list to -a instead of just one attribute, just separate them\n";
	print "    using commata, semicolon or space characters.\n";
	print "    In this case, a cross product will be produced.\n";
	print "\nEscaping special characters (\\n, etc) in -m, -s and -q:\n";
        print "    When escaping special characters as separators (eg. -m '\\\\n'), be aware that the\n";
	print "    shell also performs escaping/interpolation: with double quotes (`-m \"\\\\n`) the\n";
	print "    first backslash will be interpolated to a backslash_escape_sequence+'n' wich in\n";
	print "    turn passes '\\n' to perl, which interprets it as newline. Be sure to always use\n";
	print "    single quotes in such cases, so the shell does not interpret the argument.\n";
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
	print "  do: '$cmdname ... | recode utf8..latin1'.\n";
	print "\n  If you find bugs, please report them to the bugtracker:\n";
	print "    https://github.com/hbeni/ldap-tools/issues\n";
}
