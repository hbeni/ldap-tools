#!/usr/bin/perl -w
###########################################################################
#  Modify LDIF files with regexp and/or convert base64/wrapping.          #
#  Reads from STDIN and writes to STDOUT for happy piping                 #
#                                                                         #
#  Version: 0.9                                                           #
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
use Getopt::Std;
use MIME::Base64 qw(decode_base64 encode_base64);

my $cmdname = "ldif-preg_replace.pl";

# Some default values for the options
my $opt_regex        = 's///'; # default: do nothing, just print entries
my $opt_decoding     = 1;
my $opt_encoding     = 1;
my $opt_wraplength   = 76;  # see RFC-2849
my $opt_wrapcomments = 1;


if (scalar @ARGV == 0) {
	print STDERR "no options given.\n";
	usage();
	exit 2;
}

# Parse Options:
my %Options;
my $arg_count = @ARGV;
my $arg_ok = getopts('hf:edrw:c', \%Options);

if (!$arg_ok) {
	usage();
	exit 2;
}
if ($Options{h}) {
        usage();
	help();
        exit 2;
}

if ($Options{d}){ $opt_decoding   = 0;}
if ($Options{e}){ $opt_encoding   = 0;}
if (defined $Options{w}){
	if ($Options{w} < 2) {
		$Options{w} = 0; # disable wrapping
	}
	$opt_wraplength = $Options{w};
}
if ($Options{c}){ $opt_wrapcomments = 0;}

# GREP compatibility and filehandles
if (scalar @ARGV > 0) {
	if (scalar @ARGV >= 2) {
		# grep compatibility: grep <pattern> <file>
		$Options{r} = shift(@ARGV);
		my $infile = shift(@ARGV);
		open(INFILE, '<', $infile) or die("Unable to open $infile\n");
	}
	if (scalar @ARGV == 1) {
		if (! defined $Options{a}) {
			#grep compatibility: grep <pattern> for piping like 'grep this < from.file'
			$Options{r} = shift(@ARGV);
			open(INFILE, '-') or die("Unable to open STDIN\n");
		} else {
			# -a was given, so we assume the leftover argument must be a file
			my $infile = shift(@ARGV);
			open(INFILE, '<', $infile) or die("Unable to open $infile\n");
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
if ($Options{r}){ $opt_regex = $Options{r};}

# See if the pattern is ok
if ($opt_regex !~ /^s\/(?:[^\/]|\\\/)*?\/(?:[^\/]|\\\/)*?\/(?:[gismoxe])*$/) {
	print STDERR "Regex '$opt_regex' seems to be invalid!\n";
	exit 1;
}


#
# The code: Read linewise from STDIN, apply regexp and write result to STDOUT.
# In LDIF it is possible to fold lines, so we need to buffer the data until
# we reach a new fresh dataset.
#
my $exitcode    = 0; # all went fine
my $linebuffer  = "";
my $linecounter = 0;
while( defined(my $input = <INFILE>) ) {
	chomp($input);
	$linecounter++;
	
	# We have read a new line. This is either a folded line or a new started line,
	# which may be unfolded too.
	if ($input =~ /^\s(.+)/) {
		# Folded line. Add data to buffer for later investigation.
		$linebuffer = $linebuffer.$1;

	} else {
		# Normal line, this may be followed by folded lines.

		# If we have a buffer present, this means that we may had possible
		# folded lines, so we need to process those unwrapped line now.
		if ($linecounter > 1) {
			# only print linebuffer in case there was a chance to fill it
			# (not the case at first line... would yield a additional empty line)
			print_line(handle_line($linebuffer));
		}

		# now add the current line to the fresh buffer, as this line may
		# itself be followed by folded lines.
		$linebuffer = $input;
	}
}

# process last buffer; that is last line(s)
print_line(handle_line($linebuffer));

exit $exitcode; # time to go home


# process an unwrapped line and return result
sub handle_line {

	my $rawline = $_[0];
		
	# decode line in case base64
	my $decodedLine = $rawline;
	if ($opt_decoding && $decodedLine =~ /^(?!#)(.+?)::\s(.+)$/) {
		$decodedLine = $1.': '.decode_base64($2);
	}

	# apply regexp to line
	eval("\$decodedLine =~ $opt_regex;");

	# encode in case line contains non-ascii chars after regexp
	# The safe characters are defined in RFC-2849.
	my $encodedLine = $decodedLine;
	if ($opt_encoding && $encodedLine =~ /^(?!#)(.+?):\s(.+)$/) {
		my $attr = $1;
		my $val  = $2;
		if ($encodedLine =~ /[^[:ascii:]]/) {   # TODO: Cheap check. This is not entirely RFC conform but should work in most cases. It is safe to always encode!
			$encodedLine = $attr.':: '.encode_base64($val, '');
			chomp($encodedLine);
		}
        }

	return $encodedLine;

}


# print a line, possibly wrapping it
sub print_line {
	my $line = $_[0];
	
	if ($opt_wraplength > 0 && length($line) > $opt_wraplength) {
		$line = fixedwidth_linebreaks( $line, $opt_wraplength );
	}
	print "$line\n";
}


# wrap a string
# taken from: http://www.perlmonks.org/?node_id=51419 (credits go to davorg),
# but modified to suit LDIF needs.
# I know of Net::LDIF but wanted to avoid the dependency.
sub fixedwidth_linebreaks {
	my( $str, $width ) = @_;
	my $newstr;
	my $lcnt = 1;
	my $w = $width;
	my $ls = ($str =~ /^#/)? "# " : " ";

	if ($str =~ /^#/ && !$opt_wrapcomments) {
		return $str; # leave comments alone, if requested
	}
	while ( $str ) {
		$newstr .= substr( $str, 0, $w, '' );
		if ($lcnt >= 1 && length($str) > 0) {
			$newstr = $newstr."\n$ls";
                }
		$lcnt++;
		$w = $width-1;
	}
	return $newstr;
}




sub usage {
	print STDERR "Usage: $cmdname [options] ['s/pattern/replace/'] [file]\n";
	print STDERR "       $cmdname [options] [< data.ldif] [> result.ldif]\n";
	print STDERR "modify LDIF files using regular expressions and/or convert base64.\n";
	print STDERR "\nAvailable options:\n";
	print STDERR "  -r  Pattern to apply, in the standard form 's/pattern/replacement/[modifier]'\n";
	print STDERR "      It is advisable to quote the parameter, especially with contained spaces.\n";
	print STDERR "      Backreferences are supported the usual perl way (\$1 ..\$n).\n";
	print STDERR "  -d  Disable base64 decoding of source values (apply regexp on raw line)\n";
	print STDERR "  -e  Disable base64 encoding of target values (no base64 output)\n";
	print STDERR "  -f  LDIF-file to read from                       (default: STDIN)\n";
	print STDERR "  -w  Wrap/fold resulting LDIF at this length (<2 = disable, default: $opt_wraplength)\n";
	print STDERR "  -c  Do not wrap comments\n";
	print STDERR "  -h  Show more help and examples.\n";
}

sub help {
	print STDERR "\nReturn codes and error handling:\n";
	print STDERR "  Return codes:\n";
	print STDERR "    0: no errors\n";
	print STDERR "   >2: errors occured\n";
	print STDERR "  Normal output goes to STDOUT, while errors go to STDERR.\n";

	print STDERR "\nUse cases:\n";
	print STDERR "  This tool enables you to apply regular expressions to LDIF lines.\n";
	print STDERR "  Unlike the sed command, it can deal with LDIF files which means\n";
	print STDERR "  support for line folding and base64 encoding of values.\n";
	print STDERR "  It makes processing data much easier in a pipe with other programs,\n";
	print STDERR "  like ldapsearch, csv2ldif2 or ldif-extract.\n\n";
	print STDERR "  You can also use the tool to just decode/encode base64 values.\n";
	print STDERR "  Refolding or unfolding LDIF files is also easy, just do no replacements!\n";

	print STDERR "\nDecoding of base64 values and matching of regexp on unencoded value:\n";
	print STDERR "  LDIF files can contain non-ascii characters which according to RFC-2849\n";
	print STDERR "  are to be encoded as base64 strings. Such attributes are decoded\n";
	print STDERR "  automatically to enable regexp patterns to match against the original value.\n";
	print STDERR "  If you want to explicitely match against the base64 code, you can\n";
	print STDERR "  supply the -d option to disable base64 decoding for the checks.\n";

	print STDERR "\nEncoding of non-ascii characters in base64:\n";
	print STDERR "  The program will encode the resulting attribute values in base64, if\n";
	print STDERR "  the LDIF line contains non-ascii characters after your regex was applied.\n";
	print STDERR "  In case you want to print the raw result, disable encoding with -e.\n";

	print STDERR "\nFolding / unfolding:\n";
	print STDERR "  LDIF files can be folded to make them easier to read on terminals and basic\n";
	print STDERR "  editors. Folded lines are resolved so that the entire original value is\n";
	print STDERR "  accessible by your pattern. When writing the result LDIF, the content\n";
	print STDERR "  is wrapped again according to the parameter -w option.\n";
	print STDERR "  You can exploit this if you just want to rewrap existing LDIF files to\n";
	print STDERR "  another column width (for example to completely unwrap LDIF files!).\n";

	print STDERR "\nUsage examples:\n";
	print STDERR "  `$cmdname 's/foo/bar/' file.ldif`\n";
	print STDERR "    -> Replace the first occurence of 'foo' in each line with 'bar'.\n";
	print STDERR "       Use 's/foo/bar/g' to replace all instances of 'foo'.\n\n";
	print STDERR "  `$cmdname 's/myAttr: foo/myAttr: bar/'`\n";
	print STDERR "    -> Like above, but replaces just values of attribute 'myAttr'.\n";
	print STDERR "       Note that the dn can be accessed like ordinary attributes,\n";
	print STDERR "       just use 'dn' as <myAttr> in the example.\n\n";
	print STDERR "  `$cmdname -e file.ldif\n";
	print STDERR "    -> Decode any base64 encoded attribute values and print their\n";
	print STDERR "       original value (in your shells encoding).\n";
	print STDERR "       use the command 'recode' in case you need to convert; Directory\n";
	print STDERR "       Data is usually exported in UTF-8 (´$cmdname ... | recode utf8..?´).\n\n";
	print STDERR "  `$cmdname -d 's/foo/bar/' file.ldif\n";
	print STDERR "    -> Match regexp on the base64 code itself instead of the decoded original.\n\n";
	print STDERR "  `$cmdname -w 0 file.ldif\n";
	print STDERR "    -> Remove any wrapping from source file, so each attribute is on a single line.\n";
	print STDERR "       Note that with other values as 0 you can also easily rewrap the file.\n\n";
	print STDERR "  `$cmdname '/^(test): (foo)/\$2: \$1/' file.ldif`\n";
	print STDERR "    -> Swap attribute name and value for test ('test: foo' gets 'foo: test').\n\n";
	print STDERR "  `someCMD | $cmdname ... | $cmdname ... > result.ldif`\n";
	print STDERR "    -> Execute 'someCMD' (for example ldapsearch!) and pipe the output through\n";
	print STDERR "       two consecutive modifiers, finally writing the result to 'extract.ldif'.\n\n";
}
