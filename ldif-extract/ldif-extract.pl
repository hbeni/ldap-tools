#!/usr/bin/perl -w
###########################################################################
#  Display only certain entries from an LDIF file.                        #
#  Reads from STDIN and writes to STDOUT for happy piping                 #
#  Version: 1.6                                                           #
#  Author:  Benedikt Hallinger <b.hallinger@kubus-it.de>                  #
#                                                                         #
#  Required modules are (all core modules already present)                #
#    Getopt::Std                                                          #
#    MIME::Base64                                                         #
#                                                                         #
###########################################################################
#  This program is free software; you can redistribute it and/or modify   #
#  it under the terms of the GNU General Public License as published by   #
#  the Free Software Foundation; either version 2 of the License, or      #
#  (at your option) any later version.                                    #
#                                                                         #
#  This program is distributed in the hope that it will be useful,        #
#  but WITHOUT ANY WARRANTY; without even the implied warranty of         #
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the          #
#  GNU General Public License for more details.                           #
#                                                                         #
#  You should have received a copy of the GNU General Public License      #
#  along with this program; if not, write to the Free Software            #
#  Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111, USA. #
###########################################################################

use strict;
use Getopt::Long qw(:config no_ignore_case);
use MIME::Base64 qw(decode_base64);

my $cmdname = "ldif-extract.pl";

# Some default values for the options
my %Options = (
	'start'         => 1,
	'end'           => -1,
	'dnregex'       => '/.*/',
	'attrregex'     => '/.*/',
	'decoding'      => 1,
	'quiet'         => 0,
	'count'         => 0,
	'inverse'       => 0,
	'uniqueLines'   => 0,
	'forceComments' => 0,
	'disableLDIF'   => 0,
	'csv'           => {}, #hashRef containing CSV options
	'help'          => 0
);
# more defaults:
$Options{csv}{fs}     = ",";
$Options{csv}{fd}     = "\"";
$Options{csv}{mv}     = 1;
$Options{csv}{ms}     = "|";
$Options{csv}{decode} = 0;
$Options{csv}{attrs}  = "";


my %DOptions = %Options; # copy of defaults (for help screen)

if (scalar @ARGV == 0) {
	print STDERR "no options given.\n";
	usage();
	exit 2;
}

# Parse Options:
my $arg_count = @ARGV;
my $arg_ok = GetOptions( \%Options,
	'start|s=i',
	'end|e=i',
	'dnregex|d=s',
	'attrregex|a=s',
	'decoding|B',
	'quiet|q',
	'count|c',
	'inverse|v',
	'uniqueLines|u',
	'forceComments|J',
	'disableLDIF|S',
        'csv|C=s%{1,}',
	'help|?',
);

if (!$arg_ok) {
	usage();
	exit 2;
}
if ($Options{help}) {
        usage();
	help();
        exit 2;
}

# verify sane options
if (defined $Options{end}){
	if ($Options{start} > $Options{start}) {
        	print STDERR "ERROR: Start entry number is bigger than end entry!\n";
	        exit 2;
	}
}
if (!$Options{dnregex}) { $Options{disableLDIF} = 1; } # implicitely turn on No-LDIF when dnregex was set empty by user
if ($Options{count}){ 
	$Options{quiet} = 1;  # implicitely activated
}
foreach my $key (keys %{$Options{csv}}) {
	# verify CSV options
	if ($key !~ /^(attrs|decode|fs|fd|mv|ms)$/) {
		print STDERR "ERROR: Parameter -C: unkown option '$key'!\n";
		exit 2;
	}
}
if ($Options{csv}{mv} !~ /^[01]$/) {
        print STDERR "ERROR: Parameter -C: option 'mv' accepts only 0 or 1!\n";
	exit 2;
}
if ($Options{csv}{decode} !~ /^[01]$/) {
	print STDERR "ERROR: Parameter -C: option 'decode' accepts only 0 or 1!\n";
	exit  2;
}

# support \n and some of its friends in CSV options
foreach my $csvopt ('fs', 'fd', 'ms') {
	$Options{csv}{$csvopt} =~ s/((?<!\\)\\[tsrn])/"qq{$1}"/gee;
	$Options{csv}{$csvopt} =~ s/\\\\/\\/g;
}

# If CSV mode was requests by specifying exported attributes, print CSV header
if ($Options{csv}{attrs} ne "") {
	# print csv header
	if (!$Options{quiet}) {
		my @opt_csvfields_nice = map { $Options{csv}{fd}.$_.$Options{csv}{fd} } split(/,|\s/, $Options{csv}{attrs});
		print join($Options{csv}{fs} , @opt_csvfields_nice);
		print "\n";
	}
}



# GREP compatibility and filehandles
if (scalar @ARGV > 0) {
	if (scalar @ARGV >= 2) {
		# grep compatibility: 'grep <options> <pattern> <file>'
		$Options{attrregex} = shift(@ARGV);
		my $infile = shift(@ARGV);
		open(INFILE, '<', $infile) or die("Unable to open $infile\n");
	}
	if (scalar @ARGV == 1) {
		# grep compatibility: 'grep <options> <???>'  (<???> may either be a file or a pattern, depending of pipe usage)
		if (-t STDIN) {
			# grep compatibility: 'grep <options> <file>'   (STDIN is attached to a terminal)
			my $infile = shift(@ARGV);
			open(INFILE, '<', $infile) or die("Unable to open $infile\n");
		} else {
			# grep compatibility: 'grep <options> <pattern>'  (piping like 'grep this < from.file' or 'cmd | grep this')
			$Options{attrregex} = shift(@ARGV);
			open(INFILE, '-') or die("Unable to open STDIN\n");
		}
	}

} else {
	if ($Options{f}) {
		my $infile = $Options{f};
		open(INFILE, '<', $infile) or die("Unable to open $infile\n");
	} else {
		open(INFILE, '-') or die("Unable to open STDIN\n");
	}
}

# Sanitizing pattern syntax
if ($Options{dnregex} && $Options{dnregex}   !~ /\/.*\//) { $Options{dnregex}   = "/$Options{dnregex}/"; }
if ($Options{attrregex} && $Options{attrregex} !~ /\/.*\//) { $Options{attrregex} = "/$Options{attrregex}/"; }


#
# The code: Read from filehandle and apply checks. Process the results.
#
my $matchFound             = 1; # 1='no match found' (script returncode, not boolean)
my $errorsOccured          = 0;
my $entrycounter           = 0; # seen LDIF entries beginning with "dn:" (this is different from what getNextInputEntry() returns!)
my $entrycounter_nonLDIF   = 0; # alternative counter in case dn-regexp has been deactivated (depends just on empty lines)
my $entrycounter_matched   = 0; # overall matched entries
while( !eof(INFILE) ) {
	# Initialize some tmp variables
	my @matchLines       = ();
	my $thisEntryMatched = 0;
	my $commentOnlyEntry = 1;
	$entrycounter_nonLDIF++;

	my %tests_result = (
		dn_re     => 0,
		attr_re   => 0,
		range     => 0
        );

	
	# Retrieve and handle the next entry lines:
	# we parse a "matchable" line array that is unwrapped, this is just needed for matching however,
	# as we want to print the original (maybe wrapped?) data if it matched.
	my @entryLines = getNextInputEntry();
	foreach my $input (@entryLines) {
		
		if ($input =~ /^\s(.*)/) {
			# continued line:
			# catch error: When this happens on the first line of a new entry, there is a problem in the
			# input file (or our parsing code...): we already reported this when parsing the input file.
			if (scalar(@matchLines) == 0) {
				push(@matchLines, $input); # just add (possibly damaged) line as is
			} else {
				# this is a continuation line: add the line to the entries last match data
				chomp($matchLines[$#matchLines]); # before we do so, we must remove the most probably present newline character!
				$matchLines[$#matchLines] .= $1; # only add the value, as the sigle space is the sign for "continued line".
			}
			
		} else {
			# "normal" line:
			push(@matchLines, $input);
		}
	}


	#
	# Apply line based checks
	#
	foreach my $input (@matchLines) {

		# decode line in case base64 so regexp may apply.
		# Note again that this is only for checks, not for program output!
		my $decodedLine = $input;
		chomp($decodedLine);
		if ($Options{decoding} && $decodedLine =~ /^(.+?)::\s(.+)$/) {
			$decodedLine = $1.': '.decode_base64($2);
		}

		# Detect if this entry is only blank lines or comment
		# we may use this information to force printing of comments without counting it as match.
		# This is LDIF specific, other formats have no "comments" as we dont know the syntax format rules of the input.
		#  (somewhere in the future we may introduce a parameter to specify this...)
		if (!$Options{disableLDIF}) {
			if ( !$commentOnlyEntry || $decodedLine =~ /^(?!(\s*#)|$).*/ ) {
				$commentOnlyEntry = 0;
			}
		} else {
			$commentOnlyEntry = 0; # always consider the entry as we dont know the file syntax
		}

		
		# Apply DN-check
		# This is only applicable to dn: lines if we operate in LDIF mode
		if (!$Options{disableLDIF}) {
			if (!$tests_result{dn_re} && $decodedLine =~ /^dn::? (.+)/ ) {
				$entrycounter++; # line defines an DN: rise LDIF entry count

				if ($Options{dnregex}) {
					eval(" if (\$decodedLine =~ $Options{dnregex}) { \$tests_result{dn_re} = 1;}");
				} else {
					$tests_result{dn_re} = 1; # always true in case of disabled check
				}
			}

		} else {
			$tests_result{dn_re} = 1; # always true in case of disabled LDIF (so other tests may apply)
		}


		# Apply Attribute check
		# always applicable except for dn: lines in LDIF mode
		if ($decodedLine !~ /^dn::? (.+)/ || $Options{disableLDIF}) {
			if ($Options{attrregex}) {
				eval(" if (\$decodedLine =~ $Options{attrregex}) { \$tests_result{attr_re} = 1;}");
			} else {
				$tests_result{attr_re} = 1; # always true in case of disabled check
			}
		}


		# We can skip further tests in case both already matched
		last if $tests_result{dn_re} && $tests_result{attr_re} && !$commentOnlyEntry;
		
	} # end of line based checks


	# NOTICE: All attribute lines of the entry have been checked now.
	#         We may now apply whole-entry specific tests and then decide if the entry matched.

	# Apply range test
	my $detectLastEntry_counter = $Options{disableLDIF}? $entrycounter_nonLDIF : $entrycounter; # Depending on the mode of Operation, we need a different counter
	my $lowerEnd = $Options{start} > -1? $Options{start} : $detectLastEntry_counter; # always 'this' unless -s given
	my $upperEnd = $Options{end}   > -1? $Options{end}   : $detectLastEntry_counter; # always 'this' unless -e given
	if ($detectLastEntry_counter >= $lowerEnd && $detectLastEntry_counter <= $upperEnd) {
		$tests_result{range} = 1;
	}
#	print "DBG: RangeTest: no_ldif=$Options{disableLDIF}; s=$Options{start}; e=$Options{end}; #LDIF|#NOLDIF=$entrycounter|$entrycounter_nonLDIF ($detectLastEntry_counter >= $lowerEnd && $detectLastEntry_counter <= $upperEnd)\n";


	#
	# Handle entry match result
	#
	$thisEntryMatched = $tests_result{dn_re} && $tests_result{attr_re} && $tests_result{range};
	#print STDERR "DBG final entry test result=$thisEntryMatched (invert?:$Options{inverse}; dn_re=".$tests_result{dn_re}."; attr_re=".$tests_result{attr_re}."; range=".$tests_result{range}."; onlyComment=$commentOnlyEntry,forced=$Options{forceComments})\n";
	
	# invert match result if requested (-v)
	if ($Options{inverse}) { $thisEntryMatched = !$thisEntryMatched; }

	if ($thisEntryMatched && (!$commentOnlyEntry || $Options{forceComments})) {
		$matchFound = 0; # set return variables
		$entrycounter_matched++;
		
		if (!$Options{quiet}) {
			# print the entry, depending on selected mode
			my @csv_attrs = split(/,|\s/, $Options{csv}{attrs});
			if (scalar(@csv_attrs) > 0) {
				# CSV mode enabled!
				# for each requested attribute try to fetch the value.
				my @cur_csv_line  = ();
				foreach my $req_csv_attr (@csv_attrs) {
					my @attrVals = ();
					foreach my $attrline (@matchLines) {
						if ($attrline =~ /^(.+?)(::?)\s(.+)$/) { # attribute definition?
							my ($attr, $sep, $val) =  ($1, $2, $3);
							if (lc $req_csv_attr eq lc $attr) {
								# attribute matches requested csv field, go and add the value
								if ($Options{csv}{decode} && $sep eq "::") {
									$val = decode_base64($val);
								}
								push(@attrVals, $val);
								if (! $Options{csv}{mv}) {
									last;
								}
							}
						}
					}

					push(@cur_csv_line, $Options{csv}{fd}.join($Options{csv}{ms}, @attrVals).$Options{csv}{fd});
				}
				
				# print CSV
				print join($Options{csv}{fs}, @cur_csv_line);
				print "\n";
				
			} else {
				# print LDIF
				if ($Options{uniqueLines}) {
					# sanitize
					my %seenOutLines;
					foreach my $attrline (@entryLines) {
						if(!exists($seenOutLines{$attrline})) {
							$seenOutLines{$attrline} = 1; # store as 'seen'
							print $attrline; # and away it goes!
						}
					}

				} else {
					# just print raw entry lines (possible wrapped/encoded content!)
					print @entryLines;
				}
			}
		}
	}


	# In case we already fully processed the last selected entry we may exit, as we
	# dont need to investigate the file further (this is not the case with active inversion!)
	if ($Options{end} > -1 && $detectLastEntry_counter > $Options{end} && !$Options{inverse}) {
		last;
	}

}


# print count of matches if requested (-c)
if ($Options{count}) {
	print "$entrycounter_matched\n";
}


# Time to go home...
if ($errorsOccured) {
	exit $errorsOccured;
} else {
	exit $matchFound;
}





# Function to parse the next "entry" out of an LDIF (like-)file.
# An entry is defined as lines belonging together; that is they are separated via empty lines.
# This is neccessary because the checks need to possibly deal with entire record sets (as with -v)
# It will not handle any LDIF specific stuff like detecting attributes or base64 etc, just return the lines belonging together.
sub getNextInputEntry {
	my @return_entry = ();

	# Read some lines and investigate contents until the current entry ends.
	# The entry ends when an empty line or EOF is reached.
	my $line;
	while( defined($line = <INFILE>) ) {
		if ($line =~ /^$/) {
			# This is an empty line, the entry ends here.
			# (Note that the empty line still is part of the current entry!)
			push(@return_entry, $line);
			last; # stop processing of input file until the next function call
		}

		if ($line =~ /^\s(.*)/) {
			# This is the continuation of a prior line.
			# (Note that it is legal to continue just with an empty line...)

			# Detect error: When this happens on the first line of a new entry, there is a problem in the
			# input file (or our parsing code...): we will report this incident.
			if (scalar(@return_entry) == 0) {
				print STDERR "ERROR: continuation line found when there is nothing to continue (line $.)!\n";
				$errorsOccured = 3;
			}

			push(@return_entry, $line); # just add (possibly damaged) line as is

			next; # on to the next line
		}

		if ($line =~ /^(.+)/) {
			# this is some normal line containing data.
			push(@return_entry, $line);
			next; # on to the next line
		
		} else {
			# should never happen.
			print STDERR "ERROR: unhandled file content (line $.)!\n";
			$errorsOccured = 3;
		}
	}


	return @return_entry;
}



sub usage {
	print STDERR "Usage: $cmdname [options] [attr-pattern] [file]\n";
	print STDERR "       $cmdname [options] [< data.ldif] [> extract.ldif]\n";
	print STDERR "grep for LDIF files: Print LDIF records matching selected criterias.\n";
	print STDERR "\nAvailable options:\n";
	print STDERR "  -s  Number of the first entry to be printed  (default: $DOptions{start})\n";
	print STDERR "  -e  Number of the last entry to be printed   (default: '-1'=unlimited)\n";
	print STDERR "  -d  Regex ('/pattern/') that must match the DN of the current entry\n";
	print STDERR "      for its data to be printed  (LDIF only,  default: all entries)\n";
	print STDERR "  -a  Regex ('/pattern/') that must match an non-dn line of the\n";
	print STDERR "      current entry for its data to be printed. Will be asserted to the\n";
	print STDERR "      entire decoded LDIF line (eg 'attribute: value'; default: all lines).\n";
	print STDERR "      To explicitely match attributes use something like '/^attribute::?value/'.\n";
	print STDERR "      Use `-a ''` to disable the check (-> all lines match).\n";
	print STDERR "  -c  Just print matched entries count.\n";
	print STDERR "  -B  Disable base64 decoding for regexp checks (see -a, -d); use this\n";
	print STDERR "      in case you want to check against the raw LDIF value.\n";
	print STDERR "  -C  CSV-Options: Option 'attrs' is required to enable CSV conversion!\n";
	print STDERR "      Use several invocations of -C to set multiple options. Available are:\n";
	print STDERR "        attrs=<list> comma-or-space delimited list of attributes to be exported.\n";
	print STDERR "                     Mandatory to turn on CSV mode.\n";
	print STDERR "        decode=[0|1] Decode base64 values into raw data for CSV (default: '$DOptions{csv}{decode}')\n";
	print STDERR "        fs=<string>  Field separator (default: '$DOptions{csv}{fs}')\n";
	print STDERR "        fd=<string>  Field value delimeter (default: '$DOptions{csv}{fd}')\n";
	print STDERR "        mv=[0|1]     Enable/Disable multivalue printing of values (default: '$DOptions{csv}{mv}')\n";
	print STDERR "        ms=<string>  Separator for multiple values (default: '$DOptions{csv}{ms}')\n";
	print STDERR "      Be sure to escape commas in the lists with a single backslash.\n";
	print STDERR "  -S  Disable LDIF recognition (to process arbitary files, see -h for details!)\n";
	print STDERR "  -J  Enable matching of standalone LDIF comments and duplicate empty lines\n";
	print STDERR "  -f  LDIF-file to read from                    (default: STDIN)\n";
	print STDERR "  -u  Suppress duplicate lines                  (default: print them)'\n";
	print STDERR "  -v  Invert match result, that is print non matching entries.\n";
	print STDERR "  -q  quiet mode: do not print matching entries, just set return code.\n";
	print STDERR "  -h  Show more help and examples.\n";
	print STDERR "\n  If you find bugs, please report them to the bugtracker:\n";
        print STDERR "    https://github.com/hbeni/ldap-tools/issues\n";
}

sub help {
	print STDERR "\nReturn codes and error handling:\n";
	print STDERR "  Return codes:\n";
	print STDERR "    0: match found\n";
	print STDERR "    1: no matching entry found\n";
	print STDERR "    2: error: parameter/call error\n";
	print STDERR "    3: error: input file malformed\n";
	print STDERR "  Normal output goes to STDOUT, while errors go to STDERR.\n";

	print STDERR "\nGREP compatibility and piping:\n";
	print STDERR "  This tool is compatible to GNU GREP regarding its invocation and\n";
	print STDERR "  some parameters like -q, -f and -v as well as its return codes.\n";
	print STDERR "  As the tool reads from STDIN and writes to STDOUT, it allows piping,\n";
	print STDERR "  including chaining several invocations of the program to apply\n";
	print STDERR "  several filter conditions on the initial data (like with grep).\n";
	print STDERR "  You can redirect the input stream using normal redirection ('< file')\n";
	print STDERR "  or by supplying a filename either using -f or as the second argument.\n";
	print STDERR "  Like grep, you can supply the pattern as first argument which will\n";
	print STDERR "  be threaten as if you had given the -a parameter.\n";
	print STDERR "  Grep example: `$cmdname '/searchthis/' here.ldif`\n";

	print STDERR "\nUse cases:\n";
	print STDERR "  This tool allows you to extract LDIF entries matching user defined criteria,\n";
	print STDERR "  some kind of grep utility for LDIF. It is very useful in case you search\n";
	print STDERR "  for specific entries inside LDIF files and want to postprocess them.\n";
	print STDERR "  A common usecase is generating ldif data with the program 'ldapsearch'\n";
	print STDERR "  and applying regexp based filters, because LDAP does not support\n";
	print STDERR "  regular expressions.\n";
	print STDERR "  Another feature is the ability of -C to convert the matching entries to CSV.\n";

	print STDERR "\nNon-LDIF file support (enabling the -S option):\n";
	print STDERR "  By default, the tool assumes only real LDIF entries for range matches (-s, -e), \n";
	print STDERR "  such an entry is detectd by a 'dn:' line.\n";
	print STDERR "  The tool however supports any file whose records are separated with single blank lines.\n";
	print STDERR "  -s and -e now count any records separated with blank lines as 'entry'.\n";
	print STDERR "  Be aware that a blank line, followed by a blank line also counts as\n";
	print STDERR "  valid (but void) entry and thus increases the counter!\n";

	print STDERR "\nDecoding of base64 values and matching of regexp:\n";
	print STDERR "  LDIF files can contain non-ascii characters which according to RFC-2849\n";
	print STDERR "  are to be encoded as base64 strings. Such attributes are decoded\n";
	print STDERR "  automatically to enable regexp checks to match against the original value.\n";
	print STDERR "  if you want to explicitely match against the base64 string, you can\n";
	print STDERR "  supply the -B option to disable base64 decoding for the checks.\n";
	print STDERR "  Please note that in this case the attribute lines can be formatted with \n";
	print STDERR "  the '::' separator in case there is base64 content, and you should honor\n";
	print STDERR "  this in your regular expression.\n";

	print STDERR "\nLDIF comment handling:\n";
	print STDERR "  Unless deactivated with -S, the tool will recognize stand alone\n";
	print STDERR "  LDIF comments (eg <NewLine>#comment<NewLine>) and duplicate newlines. Such\n";
	print STDERR "  \"entries\" are ignored by default which is especially important when using\n";
	print STDERR "  the count (-c) parameter to get sane results (usually one wants the count of\n";
	print STDERR "  matching 'real entries' without LDIF comments).\n";
	print STDERR "  When enabling the -J option, you can force the inclusion of such lines in\n";
	print STDERR "  the matching, but be aware that they are also increase the count number.\n";

	print STDERR "\nGrepping for comments adjacent to entries:\n";
	print STDERR "  The attribute-regex matches for ALL lines that do not begin with 'dn:', \n";
	print STDERR "  so you can easily match comments like any other attribute: -a '/^#/' will\n";
	print STDERR "  match any comment, either stand-alone or adjacent to entries (like\n";
	print STDERR "  commented attributes in an LDIF or header comments for entries).\n";

	print STDERR "\nGrepping for attribute values:\n";
	print STDERR "  As said above, the attribute-regex matches any line, not just comments.\n";
	print STDERR "  This implies, that if you want to explicitely match just attribute\n";
	print STDERR "  names or attribute values, you have to design your regexp accordingly:\n";
	print STDERR "  -a '/^attribute: value/':\n";
	print STDERR "    - /^cn: f.*/         -> any entry whose CN starts with 'f'.\n";
	print STDERR "    - /^(?!#).+: test/   -> any entry containing  'test' in any attribute\n";
	print STDERR "                            that is not commented.\n";

	print STDERR "\nEscaping special characters (\\n, etc) in csv separator options (-C ...) :\n";
	print STDERR "    When escaping special characters as separators (eg. `-C 'fs=\\\\n'`), be aware that\n";
	print STDERR "    the shell also performs escaping/interpolation: with double quotes the\n";
	print STDERR "    first backslash will be interpolated to a backslash_escape_sequence+'n' wich in\n";
	print STDERR "    turn passes '\\n' to perl, which interprets it as newline. Be sure to always use\n";
	print STDERR "    single quotes in such cases, so the shell does not interpret the argument.\n";

	print STDERR "\nUsage examples:\n";
	print STDERR "  `$cmdname file.ldif`\n";
	print STDERR "    -> grep-like invocation example\n\n";
	print STDERR "  `$cmdname -c`\n";
        print STDERR "    -> Count number of LDIF entries (add -J to include standalone comments)\n\n";
	print STDERR "  `$cmdname -s 3 -e 5`\n";
	print STDERR "    -> Extract (print) only the LDIF entries number 3, 4 and 5.\n\n";
	print STDERR "  `$cmdname -a '/^test: foo\$/'`\n";
	print STDERR "    -> Search for entries containing attribute test with value 'foo'.\n\n";
	print STDERR "  `$cmdname -s 3 -e 5 -a '/^test: foo\$/'`\n";
	print STDERR "    -> Search for entries with test=foo in entries 3, 4 and 5; however note:\n\n";
	print STDERR "  `$cmdname -a'/^test: foo\$/' | $cmdname -s 3 -e 5`\n";
	print STDERR "    -> Search ALL entries with test=foo but only print matches 3, 4 and 5.\n\n";
	print STDERR "  `$cmdname -a '/foo/'`\n";
	print STDERR "    -> Search all entries and comments containing the string 'foo' somewhere.\n";
	print STDERR "       This matches comment lines, attribute names and attribute values!\n\n";
	print STDERR "  `$cmdname -S -a '/test/'`\n";
	print STDERR "    -> Non-LDIF example: search all entries with lines containing 'test'.\n\n";
	print STDERR "  `$cmdname -C attrs=cn,description -C 'fs=;'\n";
	print STDERR "    -> convert to CSV and print attributes 'cn' and 'description with semicolon'\n";
	print STDERR "       as separator (note the need for quoting the shell!)\n\n";
	print STDERR "  `$cmdname -u file.ldif`\n";
	print STDERR "    -> sanitize LDIF file: remove illegal duplicate lines.\n\n";
	print STDERR "  `someCMD | $cmdname ... | $cmdname ... | $cmdname ... > extract.ldif`\n";
	print STDERR "    -> Execute 'someCMD' (for example ldapsearch!) and filter the output through\n";
	print STDERR "       three filters, finally writing the result to 'extract.ldif'.\n\n";
}
