#!/usr/bin/perl
#############################################################################
#  Export LDAP entries in csv format to STDOUT                              #
#  Version: 1.11.1                                                          #
#  Author:  Benedikt Hallinger <beni@hallinger.org>                         #
#           FrenkX <FrenkX@tamotuA.de> (paging support)                     #
#                                                                           #
#  This program allows you to easily export entries to csv format.          #
#  It reads entries of an LDAP directory and prints selected attributes     #
#  in CSV format to STDOUT. Multi valued attributes will be separated by    #
#  an user definable character sequence.                                    #
#                                                                           #
#  Errors and verbose inforamtion are printed to STDERR.                    #
#  The exported data is usually in UTF8 but will be print like it is        #
#  fetched from the directory server. You can use 'recode' to convert.      #
#                                                                           #
#  Please call 'ldap-csvexpor.pl -h' for available command line             #
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
#  Hosted at Sourceforge: https://sourceforge.net/projects/ldap-csvexport/  #
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
use Time::Piece;

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
my @req_attrs;
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
my $no_csv_hdr  = 0;
my $re_dnfilter = "";
my $skip_schema = 0;
my $fixedwidth  = 0;
my $compattrsep = " ";

my @attr_flags = (); # 2-dimensional-array: attr_flags[attr-csvfield-position][chaining-level] = "flagstring"

# Sub to get real attr name and compound name from attr like "foo(bar)" or "foo([sep]bar)"
# Expects attr desc; returns array with two indexes (0=base name, 1=compound name or empty string, 2=optional separator)
sub splitCompoundAttr {
	my $attrDesc = $_[0];
	my @res;
	if ($attrDesc =~ /([\w\.]+)\((?:\[(.+?)\])?(\w+)\)/) {
		push @res, $1, $3, $2;
	} else {
		push @res, $attrDesc, "", "";
	}
	@res
}


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
my $arg_ok = getopts('1c:Chva:u:p:b:H:f:F:m:q:S:s:l:o:t:T:w:x', \%Options);
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
if ($Options{'1'}){ $singleval           = 1;}
if (defined($Options{'l'})){ $pagesize   = $Options{'l'};}
if (defined($Options{'t'})){ $contimeout = $Options{'t'};}
if (defined($Options{'T'})){ $timelimit  = $Options{'T'};}
if (defined($Options{'o'})){ $sortorder  = $Options{'o'};}
if (defined($Options{'c'})){ $sizelimit  = $Options{'c'};}
if (defined($Options{'C'})){ $no_csv_hdr = 1;}
if (defined($Options{'w'})){
	if ($Options{'w'} =~ /^-?\d+$/) {
		$fixedwidth = $Options{'w'};
	} else {
		print STDERR "-w must be a valid number!\n";
                exit 1;
	}
}
if (defined($Options{'x'})){ $skip_schema = 1;}
if ($Options{'a'}) {
	# parse attributes
	@attributes = split(/(?<!\\)\s|(?<!\\),|(?<!\\);/, $Options{'a'});
	map{ $_ =~ s/\\(\s|,|;)/\1/g } (@attributes); # remove escape chars

	# parse attribute flags ('[<?>]attrname') and chained requests
	my $p_attrpos  = 0;
	foreach my $a (@attributes) {
		my @achain_attrs = (); # cleaned version of @attributes for this attribute

		my $p_chainlvl = 0;

		# to prevent dots in format:... flag to be parsed as chain delimiter, we must escape them
		my $a_format_escaped = $a;
		if ($a =~ /(.*\[)(.+)(\].+)/) {
			my ($p1, $p2, $p3) = ($1, $2, $3);
			$p2 =~ s/\./\\./g;
			$a_format_escaped = "$p1$p2$p3";
		}

		foreach my $achain (split(/(?<!\\)\./, $a_format_escaped)) {
			my $flag = "";
			if ($achain =~ s/^\[(.+?)\]//) {
				$flag = $1;
				$flag =~ s/\\\././g; # unescape escaped dots
				if ($flag !~ /^sv$|^mv=?(.*)$|^#|fw=?(-?\d+)$|^format=[%\.a-zA-Z_-]+$/) {
					print STDERR "Unknown flag used for attribute '$a': '$flag'!\n";
					usage();
					exit 1;
				}
			}
			$attr_flags[$p_attrpos][$p_chainlvl] = $flag;

			push(@achain_attrs, $achain);
			$p_chainlvl++;
			
		}

		$a = join('.', @achain_attrs); # store clean attribute chain definition
		$p_attrpos++;
	}
}
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

# prepare requested attributes for initial query and check schema
my $ldap_schema;
if (! $skip_schema) {
	if ($verbose) { print STDERR "checking requested attributes against schema...\n"; }
	$ldap_schema = $ldap->schema(); # fetch schema object
	if (defined($ldap_schema)) {
		foreach my $a (@attributes) {
			# skip check if its a "magic" attribute
			$a =~ /^(d?dn|rdn|pdn|fix=.*)$/ && next;

			# get clean attr name
			my @sCa_ret = splitCompoundAttr($a);
			my $a_base = $sCa_ret[0];
		
			my $a_href = $ldap_schema->attribute($a_base);
			if (defined($a_href)) {
				# attribute exists
				push(@req_attrs, $a);
				if ($verbose) { print STDERR "  $a: OK\n"; }
		
			} else {
				# possible typo or chained request...
				# inspect whole chain
				my @achain = split(/\./, $a);
				foreach my $achained (@achain) {
					#TODO: add support for mixed requests eg. '(attr.attr).chained', when attr.attr is a legal attr but
		        	        #      'chained' is a chained request.... but who on earth does such things!?
					my @sCa_chain = splitCompoundAttr($achained);
					my $achained_base = $sCa_chain[0];
					#my $a_href = $ldap_schema->attribute($achained);
					my $a_href = $ldap_schema->attribute($achained_base);
					if (defined($a_href)) {
						# attribute exists!
						# in case this is the base of a chain, add it to requested  attrs
						if ($achained eq $achain[0]) {
							push(@req_attrs, $achained);
							if ($verbose) { print STDERR "  $achained: OK\n"; }
							if ($verbose) { print STDERR "  $a: OK (chained)\n"; }
						}
					} else {
						print STDERR "unknown attribute type requested: '$achained'!\n";
						exit 2;
					}
				}
			}
		}

	} else {
		# schema could not be fetched
		if ($verbose) { print STDERR "WARNING: schema could not be fetched. Skipping schema cheks, resulting in lesser performance.\n"; }
		$skip_schema = 1; # to indicate schema not accessible below
	}

} else {
        if ($verbose) { print STDERR "schema checks disabled on user request.\n"; }
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
my @req_attrs_ldap = map {my @ra = splitCompoundAttr($_); $ra[0]} @req_attrs;
my @searchArgs = (
	base      => $searchbase, 
	filter    => $filter, 
	scope     => $scope,
	attrs     => \@req_attrs_ldap,
	sizelimit => $sizelimit,
	timelimit => $timelimit,
	control   => \@controls
);


# prepare CSV header line:
my $csv_header;
foreach my $a (@attributes) {
	my $att = $a; # copy value
	if ($fixedwidth != 0) {
		$att = sprintf("%${fixedwidth}s", substr($att, 0, abs($fixedwidth))); 
	}
	$csv_header = "$csv_header$fieldquot$att$fieldquot$fieldsep";
}
$csv_header =~ s/\Q$fieldsep\E$//; # eat last $fieldsep

# set helper variables
my $csv_header_printed = 0; if ($no_csv_hdr) {$csv_header_printed = 1;}
my $exitVal = undef;
my $totalcount = 0;
my $lastPage = 0;

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
		# if no header was printed so far, do it now
		unless ($csv_header_printed == 1) {
			print "$csv_header\n";
			$csv_header_printed = 1;
		}
		
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
			if ($verbose) { print STDERR "processing page: "; }
			while (my $entry = $mesg->shift_entry()){
				if ($verbose) { print STDERR "."; }
				if ($re_dnfilter) {
					my $evalRC = eval("\$entry->dn() =~ $re_dnfilter;"); # eval regexp (eval needed to have re-options available and full re support)
					if ($evalRC) {
						if ($verbose) { print STDERR "ignored entry (-F matched): ".$entry->dn()."\n"; }
						next;
					}
				}

				# Retrieve each fields value and print it
				my $current_line = ""; #prepare fresh line
				my $csvpos = 0;
				foreach my $curattr (@attributes) {
					my $val_str = resolveAttributeValue($entry, $curattr, $csvpos, 0);

					# trim and fix width if requested globally
					if ($fixedwidth != 0) {
				                $val_str = sprintf("%${fixedwidth}s", substr($val_str, 0, abs($fixedwidth)));
				        }

					$current_line .= $fieldquot.$val_str.$fieldquot; # add field data to current line

					$current_line .= $fieldsep; # close field and add to current line
					$csvpos++;
				}
				$current_line =~ s/\Q$fieldsep\E$//; # eat last $fieldsep
				print "$current_line\n"; # print line
			}
			if ($verbose) { print STDERR "\n"; }
			# get cookie of the servers response
			$page->cookie($cookie);
			$lastPage = 0;
		}
	}
} until (defined($exitVal));

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




# Retrieve (recursively if requested) attribute values
# returns a string composed of the values
#   - empty string:    in case of errors in chained requests or no attr value set
#   - nonempty string: in case of set attr values
sub resolveAttributeValue {
	my $entry            = $_[0];  # Param 1: Entry subject
	my $curattr          = $_[1];  # Param 2: attribute name
	my $curattr_csvpos   = $_[2];  # Param 3: current index of csv field
	my $curattr_chainlvl = $_[3];  # Param 4: chaining level to process (0 for first lookup)
	my $val_str = "";
	
	# Parse attribute flags:
	# Get all stored flags for current attribute, and set defaults for unset flags
	my $all_attr_flags  = $attr_flags[$curattr_csvpos][$curattr_chainlvl];
	my $flag_sv         = ($singleval == 1); # get default for sv/mv-flag
	my $flag_count      = 0; # return values, do not just count
	my $flag_fixedwidth = 0; # no trimming
	my $flag_format     = ""; # no date formatting

	# singlevalue / multivalue flag:
	my $flag_sv = ($singleval == 1); # get default for sv/mv-flag in case it was not overridden
	my $flag_mvsep = $mvsep;
	if ($all_attr_flags =~ /(mv|sv)/) {
		$flag_sv = ($1 ne "mv");
		if ($flag_sv == 0 && $all_attr_flags =~ /mv=?(.+)/) {
			# see if there is an override for the mv-separator for this field
			$flag_mvsep = $1;
			$flag_mvsep =~ s/((?<!\\)\\[tsrn])/"qq{$flag_mvsep}"/gee; # support \n and some of its friends
			$flag_mvsep =~ s/\\\\/\\/g;
		}

	}

	# count flag
	if ($all_attr_flags =~ /#/) {
		$flag_count = 1;
		$flag_sv    = 1; # turn on mv handling for this attribute
		$val_str    = "0"; # reinitialize "attribute empty" value
	}

	# fixed-width flag
	if ($all_attr_flags =~ /fw=?(-?\d+)/) {
		$flag_fixedwidth = $1;
        }

	# date format
	if ($all_attr_flags =~ /format=(.+)/) {
		if    ($1 eq "pretty") { $flag_format = "%d.%m.%Y %H:%M:%S"; }
		elsif ($1 eq "date")   { $flag_format = "%d.%m.%Y"; }
		elsif ($1 eq "time")   { $flag_format = "%H:%M:%S"; }
		else { $flag_format = $1; } # use formatSpec as given
	}
	

	# check schema
	my @sCa_ret  = splitCompoundAttr($curattr);
	my $compattr = $sCa_ret[1];
	$curattr     = $sCa_ret[0];
	if ($entry->exists($curattr)) {
		# Attribute exists in schema, retrieve value
		# (this includes attributes with names like 'foo.bar' that look like chained requests)
		my $attr    = $entry->get_value($curattr, 'asref' => 1);
		my @values  = @$attr;

		# in case a compound attr was requested, we need to filter the results by its name
		if ($compattr ne "") {
			my $flag_compattrsep = $compattrsep;
			if ($sCa_ret[2] ne "") { $flag_compattrsep = $sCa_ret[2]; }
			if ($verbose) { print STDERR "compound attribute fetched (base='$curattr', comp='$compattr', sep='$flag_compattrsep'), filtering values...\n"; }
			my @filteredCompValues;
			foreach my $compVal (@values) {
				if ($compVal =~ /^$compattr$flag_compattrsep(.+)$/i) {
					push @filteredCompValues, $1;
				}
			}
			@values = @filteredCompValues;
		}
	

		if ($flag_count) {
			# just return count
			$val_str = scalar(@values);

		} else {
			if (!$flag_sv) {
				# retrieve all values and separate them via $mvsep
				foreach my $val (sort { return 1 if lc($a) lt lc($b); return -1 if lc($a) gt lc($b); return 0;} @values) {
					$val_str = "$val_str$val$flag_mvsep"; # add all values to field
				}
				$val_str =~ s/\Q$flag_mvsep\E$//; # eat last MV-Separator
			} else {
				# user wants only the first value
				$val_str = shift(@values);
			}

			# handle fixed-width flag at attribute-chained level
			if ($flag_fixedwidth != 0) {
				$val_str = sprintf("%${flag_fixedwidth}s", substr($val_str, 0, abs($flag_fixedwidth)));
			}

			# Format LDAP GeneralizedTime (RFC 4517)
			if ($flag_format ne "" && $val_str =~ /(\d{4}\d{2}\d{2}\d{2}\d{2}\d{2})(\.\d+)?(Z)?/) {
				my $t = Time::Piece->strptime($1, "%Y%m%d%H%M%S");
				$val_str = $t->strftime($flag_format);
			}

		}

	} elsif ($curattr =~ /^(\w+)\.(.+)/) {
		# Attribute is a chained request: resolve
		# (foo.bar.baz -> get object behind foo, from that get obj referenced by bar,
		# then from that finally get attribute baz)
		# In the first match this should give $1=>foo, $2=>bar.baz so we can recurse down.

		# get first value of reference attribute
		if ($verbose) { print STDERR "  Reference '$curattr' requested: performing entry lookup for $1@".$entry->dn()."... "; }
		if ($entry->exists($1)) {
			my $attr    = $entry->get_value($1, 'asref' => 1);
                	my @values  = @$attr;
			foreach my $dnref (@values) { # DN Reference
				my @subsearchArgs = (
					base    => $dnref,
					filter  => '(objectClass=*)',
					#attrs   => [$2],   # TODO: (better performance) Make this work, that is parse possible subchains in separate attr lists
					scope   => "base",
				);
				my $submesg = $ldap->search(@subsearchArgs);
				if ($submesg->code) {
					print STDERR "LDAP search failed!\n(Server says: ".$submesg->error."\n\n";
				} else {
					# subsearch was sucessful, try to resolve
					if ($verbose) { print STDERR "ok"; }
					my $subentry = $submesg->shift_entry();
					if ($subentry) {
						# entry was found, resolve attribute from there
						# (in case $2 contains a reference again, we will recurse)
						# Also, if the attr is a compound one, we need to adjust the syntax
						my $chainedAttrName = $2;
                				if ($compattr ne "") { $chainedAttrName = "$chainedAttrName($compattr)"; }
						if ($verbose) { print STDERR ", chainedAttrName='$chainedAttrName';"; }
						my $subval = resolveAttributeValue($subentry, $chainedAttrName, $curattr_csvpos, $curattr_chainlvl+1);
						if ($verbose) { print STDERR " foundValue='$subval'\n"; }

						# add value as MV in case it was nonempty
						if ($subval) {
							$val_str = "$val_str$subval$mvsep"; # add all values to field
						}
					}
				}

				if ($flag_sv) {
					# skip other possible values in case user requested single value handling
					last;
				}
			}

			$val_str =~ s/\Q$flag_mvsep\E$//; # eat last MV-Separator (sv+mv cases)

		} else {
			# attribute does not exist at entry:
			# -> keep empty value, which was initialized above (depending on flag)
			if ($verbose) { print STDERR "  ok (target value was empty)\n"; }
		}

	} elsif ($curattr =~ /^d?dn$/i) {
		# magic 'dn' attribute: Print full DN
		# (Some people write "ddn" instead, so this is a known alias)
		$val_str = $entry->dn;
                                
	} elsif ($curattr =~ /^rdn$/i) {
		# magic 'rdn' attribute: Print first part of DN
		my $val_dn_ref = Net::LDAP::Util::ldap_explode_dn($entry->dn);
		my @val_dn = @$val_dn_ref;
		my @rdn = (shift(@val_dn));
		$val_str = Net::LDAP::Util::canonical_dn(\@rdn);
                                
	} elsif ($curattr =~ /^pdn$/i) {
		# magic 'pdn' attribute: Print parent part of DN
		my $val_dn_ref = Net::LDAP::Util::ldap_explode_dn($entry->dn);
		my @val_dn = @$val_dn_ref;
		shift(@val_dn);
		$val_str = Net::LDAP::Util::canonical_dn(\@val_dn);

	} elsif ($curattr =~ /^fix=(.*)$/i) {
		# magic 'fix' value: Print the parameter
		$val_str = $1;

	} else {
		# fallback: no attribute found at entry.
		# (note this here is mainly for later use in case we want to handle this case
		# seperately in later versions; $val_str is empty anyway!)
		# -> keep empty value, which was initialized above (depending on flag)
	}

	

	return $val_str;  # return retrieved value(s)
}


# Usage information for help screen
sub usage {
	print "Export LDAP entries into csv format\n";
	print "Synopsis:\n";
	print "  ./ldap-csvexport.pl -a attr-list -H Host|URL -b searchbase [-t timeout]\n";
	print "                      [-1] [-m mv-sep] [-q quotechar] [-s field-sep]\n";
	print "                      [-u user-dn] [-p password] [-f filter] [-F pattern]\n";
	print "                      [-o sortoptions] [-c sizelimit] [-T timelimit] [-v]\n";
	print "  ./ldap-csvexport.pl -h\n";
	print "\nMandatory options:\n";
	print "  -a  Attribute list specifiying the attributes to export. Attributes\n";
	print "      are to be separated by space, commata or semicolon. Separators may be preserved\n";
	print "      by escaping which is useful for 'attribute flavors' or the fix-option.\n"; 
	print "      Special attributes 'dn', 'rdn', 'pdn' and 'fix':\n";
	print "        dn:    print full DN of the entry\n";
	print "        rdn:   print relative DN of the entry\n";
	print "        pdn:   print DN of parent entry\n";
	print "        fix=x: print fixed value 'x'\n";
	print "      Supports chained requests: att1.attr2 (eg. 'manager.givenName', see -h)\n";
	print "      Supports compound attributes: attr1(key) (see -h)\n";
	print "      Flags can be given by prepending the attr name with '[<flag>]attrname':\n";
	print "        'sv':     request single-value handling (useful to negate default behavior)\n";
	print "        'mv':     request multi-value handling (useful to negate parameter -1)\n";
	print "                  'mv=<sep>' can be used to override the mv-seperator for this field.\n";
	print "        '#':      print number of values instead of contents (implies [mv])\n";
	print "        'fw=<N>': set the field to fixed-width of length N (see -w below)\n";
	print "        'format=<N>': Format LDAP GeneralizedTime (eg. 'format=pretty', see -h)\n";
	print "  -b  LDAP searchbase\n";
	print "\nOptional options:\n";
	print "  -c  Sizelimit for LDAP-Search (default: unlimited)\n";
	print "  -C  Do not print CSV header\n";
	print "  -f  LDAP filter (default: '$filter')\n";
	print "  -F  Regular expression ('/<pattern>/<option>') to filter entries by DN. DNs matching\n";
	print "      the pattern will be skipped and not printed to CSV output (default: skip none).\n";
	print "  -h  Show more help than this usage information\n";
	print "  -H  LDAP server to contact (default: '$host')\n";
	print "      The basic form is [hostname|IP(:port)] like '127.0.0.1' or 'localhost:9389'.\n";
        print "      If ports are not specified, defaults will be used (389 ldap, 636 ldaps).\n";
        print "      Alternative URL: [<scheme>://<host(:port)>(/<baseDN>(?<attrs>(?<scope>(?<filter>))))]\n";
        print "      The optional items baseDN, attrs, scope and filter will override cmdline options.\n";
        print "      Example: 'ldaps://ldap.org:333/cn=base,o=ldap,dc=org?cn,[mv]mail?sub?(sn=Hall*)'\n";
	print "  -l  LDAP page size limit (default: '$pagesize', depends on your server)\n";
	print "  -m  String that is used to separate multiple values inside csv-fields (default: '$mvsep')\n";
	print "  -o  Sorting rules: '[order]<attribute>[:rule] ...' (default: unsorted)\n";
	print "      (see extended help (-h) for the rules and examples)\n";
	print "  -p  Password of user for binding (see -u; will ask if omitted)\n";
	print "  -q  String that is used to quote entire csv fields (default: '$fieldquot')\n";
	print "  -s  String that separates csv-fields (default: '$fieldsep')\n";
	print "  -S  Scope of LDAP search (default: '$scope')\n";
	print "  -t  Timeout for connection to LDAP server (default: '$contimeout' seconds)\n";
	print "  -T  Timelimit for LDAP search (default: unlimited)\n";
	print "  -w  Switch all CSV-Fields to fixed width specified (default: $fixedwidth)\n";
	print "      All values will be truncated to the field width. Negative numbers indicate\n";
	print "      left-justification, positive right-justification and 0 turns off fixed-with.\n";
	print "  -1  Prints only the first retrieved value for an attribute (instead of MV)\n";
	print "  -u  DN of user for binding (anonymous if not given)\n";
	print "  -x  Skip schema checking; is probably slower!\n";
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
	print "\nChained requests in parameter -a:\n";
	print "    Since version 1.4 you can do chained requests. This allows you to retrieve\n";
	print "    attributes from objects that are referenced by DN-links which are stored at\n";
	print "    the main object. Example: '-a manager.givenName' will resolve the entry\n";
	print "    referenced in attribute 'manager' and retrieve its 'givenName' attribute which\n";
	print "    will then be printed to your csv field. You may also do several levels of\n";
	print "    chaining like 'manager.manager.givenName' (givenName of boss of boss).\n";
	print "    Chaining by default supports multivalued references, in this case all referenced\n";
	print "    attributes will be fetched and exportet to CSV multivalue attribute.\n";
	print "    The actual behavior depends on the presence of the -1 parameter as well as\n";
	print "    flags overriding that behavior for attributes (see example below).\n";
	print "\nEscaping separator characters in parameter -a:\n";
	print "    As of release 1.3.3, the attribute sep-character may be escaped to preserve\n";
	print "    its value. This is helpful if you want to select LDAP attribute flavors.\n";
	print "    It also allows to use such characters with the fix=... option.\n";
	print "      flavor (correct): -a 'sn,description\\;lang-en' => sn, description;lang-en\n";
	print "      flavor (wrong):   -a 'sn,description;lang-en'   => sn, description, lang-en\n";
	print "      fix (correct):    -a 'sn,fix=value1\\,\\ value2'   => sn, 'value1, value2'\n";
	print "    Please note, that until 1.3.2 the escaping of the semicolon was inversed!\n";
	print "\nCompound attributes in parameter -a:\n";
	print "    Using the syntax '-a attribute(compoundname)' you can retrieve compound attribute\n";
	print "    values. They are stored in a multivalued normal attribute in syntax \n";
	print "    '<compoundname><separator><value>' and can be multivalued.\n";
	print "    Default separator is a space, but you can change it by giving it in brackets\n";
	print "    at the start of the compound spec: 'attribute([sep]compoundname)'.\n";
	print "\nDate formatting of attributes using [format=<N>] in -a:\n";
	print "    Some attribues are in GeneralizedTime syntax (RFC 4517), and returned like\n";
	print "    'YYYYmmddHHMMSSZ'. This is hard to read. By specifying the [format=<N>] flag,\n";
	print "    you can reformat such dates. See the documentation of POSIX::strftime() for\n";
	print "    format definitions. Additionally you can use the following aliases:\n";
	print "      'pretty' => '%d.%m.%Y %H:%M:%S'\n";
	print "      'date'   => '%d.%m.%Y'\n";
	print "      'time'   => '%H:%M:%S'\n";
	print "\nEscaping special characters (\\n, etc) in -m, -s and -q:\n";
        print "    When escaping special characters as separators (eg. -m '\\\\n'), be aware that the\n";
	print "    shell also performs escaping/interpolation: with double quotes (`-m \"\\\\n`) the\n";
	print "    first backslash will be interpolated to a backslash_escape_sequence+'n' wich in\n";
	print "    turn passes '\\n' to perl, which interprets it as newline. Be sure to always use\n";
	print "    single quotes in such cases, so the shell does not interpret the argument.\n";

	print "\nUsage Examples: (parameters -H and -b are ommitted for readability)\n";
	print "  $cmdname -a 'attr1,attr2,attr3' > foofile.csv\n";
	print "    -> export attr1, attr2 and attr3 to foofile.csv\n\n";
	print "  $cmdname -1 -a 'attr3 attr4' > foofile.csv\n";
	print "    -> export attr3 and attr4 but print only the first retrieved attribute\n";
	print "       value (this is not always the first value in the server!)\n\n";
	print "  $cmdname -a '[sv]attr3 [sv]attr4' > foofile.csv\n";
	print "    -> same as last command, but expressed with flags\n\n";
	print "  $cmdname -a 'attr5\\;attr6' -m '-' -q '/' > foofile.csv\n";
	print "    -> export attr5 and attr6. If one has multiple values, they will be separated by\n";
	print "       the minus character. Additionally, quote entire csv fields with a\n";
	print "       forward slash. resulting cvs line like: \"/val1-val2-val3/attr6v1\"\n\n";
	print "  $cmdname -a 'attr1,fix=fooBar,attr3'\n";
	print "    -> export attr1, fixed value 'fooBar' and then attr3 \n\n";
	print "  $cmdname -a 'attr1,fix=foo\ Bar,attr3'\n";
	print "    -> export attr1, fixed value 'foo Bar' and then attr3 \n\n";
	print "  $cmdname -a 'cn,manager.mail'\n";
        print "    -> export cn, and all mail adresses of all linked managers\n\n";
	print "  $cmdname -a 'cn,manager.mail' -1\n";
        print "    -> export cn, and first mail adresses of first linked manager\n\n";
	print "  $cmdname -a 'cn,manager.[sv]mail'\n";
	print "    -> export cn, and first mail adresse of all linked managers\n\n";
	print "  $cmdname -a 'cn,[format=%d.%m.%Y]createTimestamp'\n";
	print "    -> export cn and createTimestamp, formatted like '31.12.2099'\n";
	print "\nSorting:\n";
	print "  The sorting paramter consists of an attribute that may be enriched by an order flag\n";
	print "  and optionally an alternating sorting rule ('[order]<attribute>[:rule]'). Examples:\n";
	print "    'cn'         sort by cn using the default ordering rule for the cn attribute\n";
	print "    '-cn'        sort by cn using the reverse of the default ordering rule\n";
	print "    'age cn'     sort by age first, then by cn using the default ordering rules\n";
	print "    'cn:1.2.3.4' sort by cn using the ordering rule defined as 1.2.3.4\n";
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
	print "\n  If you find bugs, please report them to the SF bugtracker:\n";
	print "    https://sourceforge.net/projects/ldap-csvexport/\n";
}
