#!/usr/bin/perl
#############################################################################
#  Replace values of LDAP attributes online based on a regular expression   #
#  Version: 1.1.2                                                           #
#  Author:  Benedikt Hallinger <beni@hallinger.org>                         #
#                                                                           #
#  This program allows you to apply an s/from/to/ pattern online to         #
#  an attribute inside some directory server. The regular expression        #
#  allows for maximum flexibility and enables you to clean out specific     #
#  values based on some conditions.                                         #
#  Please call 'ldap-preg_replace.pl -h' for available command line         #
#  options and additional information.                                      #
#                                                                           #
#  Required modules are                                                     #
#    Net::LDAP                                                              #
#    Getopt::Long                                                           #
#  You can get these modules from your linux package system or from CPAN.   #
#                                                                           #
#  Hosted at: https://github.com/hbeni/ldap-tools/issues                    #
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
use 5.014; # so keys/values/each work on scalars
use Switch;
use Getopt::Long qw(:config no_ignore_case);
use Net::LDAP;
use Net::LDAPS; # TODO: Implement SSL/TLS support: http://search.cpan.org/dist/perl-ldap/lib/Net/LDAPS.pm
use Net::LDAP::Util;
use Net::LDAP::LDIF;
use Net::LDAP::Control::Sort;
use Net::LDAP::Control::Paged;
use Net::LDAP::Constant qw( LDAP_CONTROL_PAGED );

# autoflush STDOUTand STDERR
select(STDERR); $| = 1;
select(STDOUT); $| = 1;

my $called_at = time();

#####################
# Optionsmanagement #
#####################

# Defaults:
my %Options = (
	'host'           => 'ldap://localhost:389/',
	'timelimit'      => 0,
	'sizelimit'      => 0,
	'pagesize'       => 300,
	'base'           => undef,
	'scope'          => 'sub',
	'user'           => '',
	'pass'           => undef,
	'filter'         => '(objectclass=*)',
	'overridefilter' => '',
	'rule'           => {}, # hashRef containing "attribute1"=>[rule1, rule2, ruleN, ...], "attribut2" => [rules...]
	'help'           => 0,
	'dryrun'         => 0,
	'verbose'        => 0,
	'yes'            => 0,
	'ask'            => 0,
	'ldif'           => ''
);
my %DOptions = %Options; # copy of defaults (for help screen)


# Mask password parameter if given, so it wont show at process list
# (Note that this is not secure as there is a brief period during
#  which the password is in cleartext in the process list.)
my $cmdname = $0;
my $cmdline = "$0";
my $lo = "";
foreach my $o (@ARGV) {
	if ($lo =~ /-p/) {
		$cmdline = "$cmdline ***";
	} else {
		$cmdline = "$cmdline $o";
	}
	$lo = $o;
}
$0 = $cmdline;

# Parse options using Getopt:
my $arg_count = @ARGV;
sub opt_ruleHandler {
	# getOpt handler to handle mutliple rules for a single attribute
        my ($opt_name, $opt_key, $opt_value) = @_;
	if (! $Options{$opt_name}{$opt_key} ) {
		# key does not exist: initialize it
		my @tmpArray = ($opt_value);
		$Options{$opt_name}{$opt_key} = [@tmpArray];
	} else {
		# key does exist: dereference and push
		push (@{$Options{$opt_name}{$opt_key}}, $opt_value);
	}
}
my $arg_ok = GetOptions( \%Options,
	'a|A',  # reserved/obsolete since 1.0. Will print error message, see below.
	'host|h|H:s',
	'timelimit|t=i',
	'sizelimit|s=i',
	'pagesize|P=i',
	'base|b=s',
	'scope|S=s',
	'user|u=s',
	'pass|p=s',
	'filter|f=s',
	'overridefilter|Filter|F=s',
	'rule|r=s%{1,}' => \&opt_ruleHandler,
	'help|?',  # note the missing h, as this is assigned to "host", see below for special handling
	'dryrun|d',
	'verbose|v+',
	'yes|y|Y',
	'ask',
	'ldif=s'
);

# show help and terminate if requested;
# note that "-h" may be ambigous. "-h <noParam>" is treated as help.
if ($Options{help} || $Options{host} eq "") {
       usage();
       help();
       exit 0;
}
if (!$arg_ok) {
       usage();
       exit 9;
}
if (defined $Options{a}) {
	# Option -a/-A was used in version <1.0 to denote the attribute to be processed.
	# this changed with the new rules syntax.
	# If someone did call this tool with -a, then we should print out a warning.
	print STDERR "Unknown option: a! Since version 1.0 -a and -A is unused (this may change in the future!)\n";
	print STDERR "Please use the new syntax of -r, or did you mean --ask? ";
	print STDERR "see -h for help/usage information.\n";
	exit 9;
}
if ($Options{host} =~ /^(ldap[si]?:\/\/.+?)\/(.+)/i) {
	# baseDN (and possibly otheroptions) was supplied in host parameter, so we use it.
	# It takes precedence over parameters on command line.
	$Options{host} = $1;
	my @queryspec = split(/\?/, $2);
	if (defined $queryspec[0]) {$Options{base} = $queryspec[0];}
	# $queryspec[1] holds attributes which are meaningless in this application
	if (defined $queryspec[2] && $queryspec[2] ne "") {$Options{scope} = $queryspec[2];}
	if (defined $queryspec[3] && $queryspec[3] ne "") {$Options{filter} = $queryspec[3];}
}

# DEBUG Options:
# before sanitizing and after processing, print out all options in current parsed state
if ($Options{verbose} ge 3) {
        print "DBG: Options set:\n";
        for my $key ( keys %Options ) {
                my $value = $Options{$key};
                print "DBG:   $key => $value\n";

                if ($key eq "rule") {
                        my $i = 1;
                        for my $rk ( keys %{$Options{rule}} ) {
                                my @rule_values = @{$Options{rule}{$rk}};
                                my $v=1;
                                for my $r (@rule_values) {
                                        print "DBG:     RULE-$i.$v: attr='$rk'; rule='$r'\n";
                                        $v++;
                                }
                                $i++;
                        }
                }
        }
}

# check for missing mandatory parameters
foreach my $o ('base', 'rule') {
	if ( !defined($Options{$o}) || (ref($Options{$o}) eq "HASH" && keys %{$Options{$o}} == 0) ) {
		print STDERR "Option --$o is mandatory!\n";
		usage();
		exit 9; 
	}
}

# verify sane options
if ($Options{scope} !~ /^(base|one|sub)$/) {
	print STDERR "Option scope must be one of 'base', 'one' or 'sub'!\n";
	exit 9;
}

if ($Options{'rule'}) {
	# check all the rules for proper syntax
	# (we need to do this here because all options must already be parsed
	for my $rk ( keys %{$Options{rule}} ) {
		# See if the pattern is now ok
		# If we think its not ok, lets ask the user if he wants
		# to continue. This is because we dont have ultimative wisdom
		# and may check the regex wrong.
		# Feel free to debug/improve the following regex and send me
		# a patch so we reach the uber-regex.
		for my $rvalue(@{$Options{rule}{$rk}}) {
			if ($rvalue !~ /^s\/(?:[^\/]|\\\/)+?\/(?:[^\/]|\\\/)*?\/(?:[gismoxe])*$/) {
				print STDERR "Warning: attribute='$rk', rule='$rvalue': Regex seems to be invalid! Continue? (y/N) ";
				if (!$Options{yes}) {
					my $i;
					$i = readline; 
					if ($i !~ /^(y|j)$/i) {
						print STDERR "aborted.\n";
						exit 0;
					}
				} else {
					print STDERR "Y\n";
				}
			} else {
				if ($Options{verbose} ge 2) {
					print "DBG: checking rule syntax: attribute='$rk', rule='$rvalue': OK\n";
				}
			}
		}

	}
}

# Initialize ldif_change_writer in case ldif was requested
my $ldif_change_writer;
if ($Options{ldif}) {
	$ldif_change_writer = Net::LDAP::LDIF->new( $Options{ldif}, "w", (onerror=>'undef', version=>'1', change=>1, encode=>'base64', wrap=>0) );
	if (!defined $ldif_change_writer) {
		print STDERR "ERROR: could not open LDIF-change file '$Options{ldif}'.\n";
		exit 2;
	}
}

# Get credentials if authenticated bind was requested
if ($Options{user}){
	if (!defined $Options{pass}) {
		if (-t STDIN) {
			# ask user interactively for password
			print STDERR "LDAP password: ";
			system('stty','-echo');
			chomp($Options{pass}=<STDIN>);
			system('stty','echo');
			print STDERR "***\n";
		} else {
			# no tty: just grab one line from STDIN
			chomp($Options{pass}=<STDIN>);
		}
	}
}


my $exitcode = 0; # exit code for final end
#######################################
## Search entries and apply regex     #
#######################################

# initialize statistical variables
my $stat_replacements    = 0; # overall replaced values
my $stat_changed_entries = 0; # overall changed entries
my $stat_failed_entries  = 0; # entries where update failed
my $stat_found_entries   = 0; # overall processed entries

# Investigate ruleset: get all requested attributes
my @attrsRequested = keys %{$Options{rule}};

# Connect and bind to server
if ($Options{verbose} ge 2) { print "DBG: Connect to LDAP-Host '$Options{host}'\n"; }
my $ldap = Net::LDAP->new( $Options{host}, timelimit => $Options{timelimit});   # LDAP-connect
if (!$ldap){
	print STDERR "Could not connect to $Options{host}!\n(Server says: $@)\n\n";
	exit 2;
}
if ($Options{user}) {
	if ($Options{verbose} ge 2) { print "DBG: Bind as user '$Options{user}'\n"; }
	my $mesg = $ldap->bind($Options{user}, 'password' => $Options{pass});
	if($mesg->code){
		print STDERR "Authentication failed!\n(Server says: ".$mesg->error.")\n\n";
		exit 2;
	}
} else {
	if ($Options{verbose} ge 2) { print "DBG: Bind as anonymous\n"; }
	my $mesg = $ldap->bind();
	
}

# Build up LDAP filter: For performance reasons we just want the
# entries that have values for the attribute requested.
# Thus, we generate an adequate LDAP filter matching only
# those entires.
# This must be suppressed for example in case we want to add
# Values to empty attributes.
if ($Options{verbose} ge 2) { print "DBG: Building LDAP Filter\n"; }
my $filter;
if ( !$Options{overridefilter} ) {
	my @attrsRequested_forFilter;
	for my $fattr (@attrsRequested) {
		push(@attrsRequested_forFilter, "$fattr=*");
	}
	my $tunedFilter = join(')(', @attrsRequested_forFilter);
	$tunedFilter = "($tunedFilter)";
	$filter = "(&$Options{filter}(|$tunedFilter))";
} else  {
	# -F was given, use Filter as is
	$filter = $Options{overridefilter};
}

# Fetch schema entry so we may optimize a little
my $ldap_schema;
if ($Options{verbose} ge 2) { print "DBG: Fetching LDAP schema\n"; }
$ldap_schema = $ldap->schema();
if (defined $ldap_schema) {
	# check that each requested attribute actually exists in the server
	foreach my $attr (@attrsRequested) {
		if ($Options{verbose} ge 2) { print "DBG:   schemacheck '$attr': "; }
		if (!defined($ldap_schema->attribute($attr))) {
			if ($Options{verbose} ge 2) { print "ATTRIBUTE_NOT_FOUND\n"; }
			print STDERR "ERROR: requested attribute '$attr' not found in server!\n";
			exit 10;
		} else {
			if ($Options{verbose} ge 2) {
				print "OK "; 
				if (${$ldap_schema->attribute($attr)}{'single-value'}) {
					print "(single-value)\n";
				} else {
					print "(multi-value)\n";
				}
			}
		}
	}
} else {
	print STDERR "Warning: LDAP schema could not be fetched - all attributes will be treaten as multi-valued.\n";
}


# Setup search controls
my @activeControls = ();
my %activeControlsOpts;

if ($Options{pagesize} gt 0) {
	# SimplePaging control
	# see http://search.cpan.org/~gbarr/perl-ldap-0.43/lib/Net/LDAP/Control/Paged.pm
	if ($Options{verbose} ge 2) { print "DBG: Initializing SimplePagingControl with pagesize=$Options{pagesize}\n"; }
	$activeControlsOpts{SimplePaging}{controlObj} = Net::LDAP::Control::Paged->new( size => $Options{pagesize});
	$activeControlsOpts{SimplePaging}{cookie} = undef;
	push (@activeControls, $activeControlsOpts{SimplePaging}{controlObj});
}


# Prepare search operation
my $pageNumber = 1;
my $pageNumber_lastSeen = -1; # for printing stats in callback
if (!defined $activeControlsOpts{SimplePaging}{controlObj}) { $pageNumber = "PAGING_DISABLED";} # for nicer debug output
my @ldapSearchArgs = (
	base      => $Options{base},
	scope     => $Options{scope},
	filter    => $filter,
	attrs     => [@attrsRequested],
	callback  => \&process_entry_callback, # Call this sub for each entry
	control   => \@activeControls,
	timelimit => $Options{timelimit},
	sizelimit => $Options{sizelimit}
);

while (1) {
	# Perform search operation
	# The search returns entries as the server sends them. Each entry is then
	# processed by the callback subroutine. This saves time and ressources.
	if ($Options{verbose} ge 1) { print "\nPerform search: filter='$filter', nextPage='$pageNumber'\n"; }
	my $search = $ldap->search( @ldapSearchArgs );
	if ($search->code){
		my $errortext = $search->error();
		my $errorcode = $search->code();
		my $errorname = $search->error_name();

		# handle error codes differently, as some codes arent merely errors.
		switch ($errorcode) {
			case [3,4] {
				# timelimit/sizelimit exceeded - partial results, but OK
				print STDERR "INFO: $errortext\n";
			}
			else {
				print STDERR "LDAP ERROR $errorcode ($errorname): $errortext\n";
				$exitcode = 10;
			}
			
		}

		last; # abort processing
	}

	# Get cookie from paged control and store it for next search request
	if (defined $activeControlsOpts{SimplePaging}{controlObj}) {
		# we stop processing in case of errors/ cookie undef.
		my $resp = $search->control( LDAP_CONTROL_PAGED ) or last;
		$activeControlsOpts{SimplePaging}{cookie} = $resp->cookie or last;
		$activeControlsOpts{SimplePaging}{controlObj}->cookie($activeControlsOpts{SimplePaging}{cookie});

		$pageNumber++;

	} else {
		# paging is disabled, so we perform only one search which should
		# already be fully processed by now.
		last;
	}
}
if ($Options{verbose} ge 2 && defined $activeControlsOpts{SimplePaging}{controlObj}) { print "DBG: all $pageNumber pages processed.\n"; }

# Check for abnormal loop exit and tell the server we finished processing.
# This is done by issuing the same search with pagesize=0.
# We detect the interruption when the cookie was not reset properly at the last page,
# because the LDAP server delivers only a cookie for remaining pages.
if (defined $activeControlsOpts{SimplePaging}{controlObj}) {
	# ... but only if paging was requested in the first place.
	if ($activeControlsOpts{SimplePaging}{cookie}) {
		$activeControlsOpts{SimplePaging}{controlObj}->cookie($activeControlsOpts{SimplePaging}{cookie});
		$activeControlsOpts{SimplePaging}{controlObj}->cookie->page(0);
		$ldap->search(@ldapSearchArgs);
		if ($Options{verbose} ge 2) { print "DBG: abnormal termination of search operation detected!"; }
	}
}



# This sub defines the callback used by the search operation.
# see:
#  - http://search.cpan.org/~marschap/perl-ldap/lib/Net/LDAP.pod#CALLBACKS
#  - http://search.cpan.org/~gbarr/perl-ldap/lib/Net/LDAP/FAQ.pod#GETTING_SEARCH_RESULTS
sub process_entry_callback {
	my $mesg  = $_[0];
	my $entry = $_[1];
	my $debug_entryprint       = 0; # prevents DN printing more than once
	my $replacements_thisentry = 0; # shows if we modified the current entry ie need to update()

	# Check if we have a valid entry object, if not, return silently.
	# (last execution of callback subroutine will have no defined entry and mesg object)
	if ( !defined($entry) ) {
		return;
	}

	$stat_found_entries++;  # record new processed entry for statistical reasons

	# Process all the rules:
	my $ruleAttrNr = 0;  # for debug output
	for my $attribute ( keys %{$Options{rule}} ) {
		$ruleAttrNr++;

		# Fetch LDAP values of the attribute of the rule
		my $rep_attr  = $entry->get_value($attribute, 'asref' => 1);
		my @values = ();
		if (defined $rep_attr) {
			@values = @$rep_attr; # Values found, dereference values
		}

		# Detect mode: single-valued or multi-valued?
		# Fallback is multivalue-mode.
		my $attrModeMV = 1;
		if ( defined $ldap_schema && ${$ldap_schema->attribute($attribute)}{'single-value'} ) {
			$attrModeMV = 0;
		}
		
		# Append an empty string to the end as "pseudovalue";
		# this is neccessary to allow patterns like /^$/ to match, i.e. allow to add attribute values.
		# Note that this behaves differently depending the LDAP filter used (see help text for details).
		# In case of SV-Attribute, we only add in case there is no value yet to allow addition.
		if ( $attrModeMV || (!$attrModeMV && (scalar @values) == 0) ) {
			push(@values, '');
		}


		# Perform replacements: apply all rules of this attribute to all values
		# (this is done in memory, final update occurs later on)
		my $ruleRegexNr = 0; # for debug output
		for my $regex (@{$Options{rule}{$attribute}}) {
			$ruleRegexNr++;
			foreach my $value (@values) {
				my $oldvalue = $value;
				my $newvalue = $value;
				my $evalRC = eval("\$newvalue =~ $regex;"); # apply regexp. Note that it is not escaped (variables can be used)

				# store possible change in-memory (for following rules)
				my @oldValues = @values;
				$value = $newvalue;

				if ($Options{verbose} ge 2) {
					if ($evalRC) {$evalRC="yes";} else {$evalRC="no";} # for nicer debug output
					if ($debug_entryprint == 0) {print "\n".$entry->dn()."\n"; $debug_entryprint = 1;}
					print "  DBG: apply RULE-$ruleAttrNr.$ruleRegexNr: attr='$attribute'; regexp='$regex'; match=$evalRC; value='$oldvalue'\n";
				}

				# Evaluate outcome of rule (did the value change?)
				if ( ! attr_compare_equal($attribute, $newvalue, $oldvalue) ) {
					if ($debug_entryprint == 0 && $Options{verbose} ge 1) { print "\n".$entry->dn()."\n"; $debug_entryprint = 1; }
					$stat_replacements++;
					$replacements_thisentry++;
					
					if ($newvalue eq "") {
						# new value is empty: delete attribute value (only with nonempty old values)
						if ($oldvalue ne "") {
							$entry->delete($attribute => [ $oldvalue ]);
							if ($Options{verbose} ge 1) { print "  deleting $attribute '$oldvalue'\n"; }
						}

					} else {
						# replace old value with new one (modify or add)
						# note that the remove-then-add systematic has benefits beyond the detection
						# capabilitys, as this way we can change arbitary attribute syntaxes (like case-insensitive DIR_STR)
						my $additionalMessage = "";
						if ($oldvalue ne "") {
							# modify: in case old value was nonempty we must cleanout the obsolete old value
							$entry->delete($attribute => [ $oldvalue ]);

							# add new value only if not already present
							if ( ! in_array($attribute, $newvalue, @oldValues) ) {
								$entry->add($attribute => $newvalue);
							} else {
								$additionalMessage = "(value already exists)";
							}

	                                                if ($Options{verbose} ge 1) { print "  replacing $attribute '$oldvalue' with '$newvalue' $additionalMessage\n"; }

						} else {
							# add: just add new value
							# in case we had the "pseudo-empty value" replaced, we need to add
							# another one so (possibly) following rules can match too.
							# however, to prevent an endless loop for the current rule, we must
							# abort its further evaluation. This is however not a problem as the
							# empty-value is considered at the values-array end.
							# We need only do all of this in case the new value is not yet present.
							if ( ! in_array($attribute, $newvalue, @oldValues) ) {
								$entry->add($attribute => $newvalue);
								if ($Options{verbose} ge 1) { print "  adding $attribute '$newvalue' $additionalMessage\n"; }

								# if we operate in single-value mode we don't add a new empty value,
								# the obvious reason is that the attr can only hold one value at most...
								if ($attrModeMV) {
									push(@values, '');
								}
								last; # skip to next rule
							} else {
								$additionalMessage = "(value already exists)";
								$replacements_thisentry--; # to avoid update() in case this is the only change
								$stat_replacements--; # correct statistics
							}
							
							if ($Options{verbose} ge 1) { print "  adding $attribute '$newvalue' $additionalMessage\n"; }

						}
					}
				} else {
					if ($Options{verbose} ge 2 && $evalRC eq "yes") { print "  DBG:  no value change detected\n"; }
				}
			}
		}

	}


	# All rules on this entry processed: apply changes to LDAP
	if ($replacements_thisentry > 0) {

		# Ask user to confirm update (if he requested it with --ask)
		if ($Options{ask}) {
			if ($debug_entryprint == 0) {print "\n".$entry->dn()."\n"; $debug_entryprint = 1;}
			print STDERR "Perform update? [Y|n] ";
			if (!$Options{yes}) {
				my $i;
				$i = readline;
				if ($i =~ /^(n)$/i) {
					print "skipped.\n";
					next;
				}
			} else {
				print "Y\n";
			}
		}

		$stat_changed_entries++;

		# write LDIF change record in case it was requested
		if ($Options{ldif} ne "") {
			if ($Options{verbose} ge 2) { print "  DBG: Entry changed -> wrote to LDIF-change-file '$Options{ldif}'\n"; }
			$ldif_change_writer->write_entry($entry);
		}
		
		# Perform update if not in dry run mode
		if (! $Options{dryrun}) {
			if ($Options{verbose} ge 2) { print "  DBG: Entry changed -> updating\n"; }
			my $umsg = $entry->update($ldap);
			if ($umsg->code) {
				my $errortext = $umsg->error();
				print STDERR "  FAILED updating entry! $errortext (".$entry->dn().")\n";
				$stat_failed_entries++;
				$exitcode = 1;
			}
		}
	}

}

if ($Options{verbose} ge 2) { print "DBG: undbind and closing LDAP connection\n"; }
$ldap->unbind();
$ldap->disconnect();

# Print out statistical information
if ($Options{verbose} ge 0) {
	print "\n";
	my $runtime = time() - $called_at;
	print "$stat_replacements values of $stat_changed_entries entries modified in $runtime seconds, analyzed $stat_found_entries entries.\n";
	if ($Options{dryrun}) {
		print "(no real updates where performed due to dry-run)\n";
	}
}


# Exit
if ($exitcode eq 1) {
	print STDERR "$stat_failed_entries entries could not be modified successfully.\n";
}
exit $exitcode;



# Usage information for help screen
sub usage {
	print "Replace values of LDAP attributes online based on regular expressions\n";
	print "Synopsis:\n";
	print "  ./ldap-preg_replace.pl -b searchbase -r attribute=regexp [-r attribute=regexp]\n";
	print "                         [-H host|URL] [-u user-dn] [-p password] [-f|-F 'Filter']\n";
	print "                         [-s <base|one|sub>] [-t timelimit] [-l file.ldif]\n";
	print "                         [-P pagesize] [-d] [-v [-v]] [-y] [--ask]\n";
	print "  ./ldap-preg_replace.pl -h\n";
	print "\nMandatory options:\n";
	print "  -b, --base      Searchbase for LDAP search, could also be specified by URL in -H.\n";
	print "  -r, --rule      One ore more rules specify the regexp for the relevant attributes.\n";
	print "                  Multiple rules per attribute are supported. The option syntax is:\n";
	print "                  '<attribute>=s/<pattern>/<replacement>/<options>'. Note that the\n";
	print "                  pattern will be evaluated against an empty attribute value, giving\n";
	print "                  the patterns '^' and '\$' special meaning. (see -h for examples).\n";
	print "                  The Rules will be processed in order of parameter appearance, and\n";
	print "                  following rules may manipulate the result of prior rules.\n";
	print "                  Note that PCRE syntax is required and fully supported.\n";
	print "                  Also note that you should probably quote the parameter for the shell.\n";
	print "                  Some special characters (\$, \@, \%) need sometimes quoting as well.\n";
	print "\nOptional options:\n";
	print "  --ask           Ask user before performing entry update.\n";
	print "  -d, --dryrun    Do not send updates to server.\n";
	print "  -f, --filter    LDAP filter (default: '$DOptions{filter}'). Performance-tuning: This\n";
	print "                  filter will be AND-combined using OR-ed filter components checking for\n";
	print "                  existing attribute values for each attribute requested in your rules.\n";
	print "                  Essentially this means that only entries with at least one present value\n";
	print "                  for one of the requested attributes will be modified by default.\n";
	print "                  Be sure to quote the filter as round  brackets usually confuse the shell;\n";
	print "                  again, see -h for examples and furhter explaination.\n";
	print "  -F, --overridefilter  Like -f, but disables performance tuning; your specified\n";
	print "                  filter will be used as-is. Option -F overrides -f when given.\n";
	print "  -h, --help      Show more help than this short usage information.\n";
	print "  -H, --host      LDAP server to contact (default: '$DOptions{host}').\n";
	print "                  The basic form is [hostname|IP(:port)] like '127.0.0.1' or 'localhost:9389'.\n";
	print "                  If ports are not specified, defaults will be used (389 ldap, 636 ldaps).\n";
	print "                  Alternative URL: [<scheme>://<host(:port)>(/<baseDN>(??<scope>(?<filter>)))]\n";
	print "                  The optional items baseDN, scope, filter will override cmdline options.\n";
	print "                  Example: 'ldaps://ldap.org:333/cn=base,o=ldap,dc=org??sub?(sn=Hall*)'\n";
	print "  -l, --ldif      Write LDIF-change records to the file specified. This is especially\n";
	print "                  useful in combination with --dryrun to exclusively generate LDIF files.\n";
	print "  -p, --pass      Password of user for binding (see -u; will ask if omitted).\n";
	print "  -P, --pagesize  LDAP pagesize, 0=disable paging (default: $DOptions{pagesize})\n";
	print "  -S, --scope     Scope of LDAP search (default: '$DOptions{scope}').\n";
	print "  -s, --sizelimit Maximum number of entries to be processed, '0' means no limit (default: '$DOptions{sizelimit}').\n";
	print "                  Note that the server may enforce lower server side limits.\n";
	print "  -t, --timelimit Maximum seconds allowed for the search, '0' means no limit (default: '$DOptions{timelimit}').\n";
	print "                  Note that the server may enforce lower server side limits.\n";
	print "  -u, --user      User-DN of user for binding to LDAP server (anonymous if not given).\n";
	print "  -v, --verbose   Show what the program does. Multiple occurrences increase verbosity:\n";
	print "                  '-v': verbose; '-v -v': verbose+debug.\n";
	print "  -y, --yes       Say 'yes' to all prompts.\n";
}

# Prints extendet help
sub help {
	print "\n\nAdditional information:\n";
	print "  Exit codes are as following:\n";
	print "    0 = everything was ok\n";
	print "    1 = at least one entry update failed\n";
	print "    2 = connection error\n";
	print "    9 = parameter error\n";
	print "   10 = LDAP protocol error\n";
	print "\n";
	print "  Normal and Debug output goes to STDOUT,\n";
	print "  Error messages and user prompts go to STDERR.\n";

	print "\nGeneral usage and adding of values:\n";
	print "  The tool binds to the specified LDAP server and searches online for entries.\n";
	print "  Each found entry will be subject to the specified modification rules, possibly\n";
	print "  modifying the relevant attribute of the current rule if a match occured.\n";
	print "  The entries that should be subjected to rules are defined by a LDAP filter.\n";
	print "\n";
	print "  In addition to the values present at the entry, the program will evaluate the\n";
	print "  rules against an empty string value (''). This makes it possible to add values\n";
	print "  to attributes by matching the line-start and line-end patterns (^ and \$). Care\n";
	print "  must be taken in such cases to yield the desired result, especially if you want\n";
	print "  to add values exclusiveley to empty attributes or want to add post- or prefixes\n";
	print "  only to existing values (see details and examples below).\n";
	print "  If the LDAP schema could be fetched, the behavior is subject to the attributes\n";
	print "  syntax: at single-valued attributes the empty string is only matched one single\n";
	print "  time if there is no initial value (eg. empty SV-Attribute).\n";

	print "\nPerformance tuning (using -f and -F):\n";
	print "  If the filter is given with -f, then the rules will be examined to optimize\n";
	print "  the search operation. Usually one wants to only consider entries that have\n";
	print "  values for the requested attribute rules. The user filter is thus enhanced\n";
	print "  with a condition that returns only entries with values for at least one\n";
	print "  of your rules. You must specify a suitable filter if you have stronger\n";
	print "  requirements than this. Also you may consider option -F to do it all manually.\n";
	print "  Using -F will turn off that tuning, resulting in the filter used as specified.\n";
	print "  Note that a filter also supplied with -f is ignored when -F is present.\n";

	print "\nRegular Expressions - Hints:\n";
	print "  RegExp are very powerful, so read: http://perldoc.perl.org/perlretut.html.\n";
	print "  You may use Backreferences of the form \$(patterngroup): eg. 's/ba(r|z)/\$1/'\n";
	print "  will replace 'bar' or 'baz' with 'r' or 'z'.\n";
	print "  The patterns are case sensitive by default, so use modifier 'i' to make them\n";
	print "  case insensitive. This may be confusing because usually string attributes\n";
	print "  are case insensitive by default: 's/matchme/replace/i'.\n";
	print "  The patterns will match only one time normally, so 's/a/X/' will only replace\n";
	print "  the first occurence of 'a' ('aabb' -> 'Xabb'). if you want to replace all\n";
	print "  occurrences, you need to supply the 'g' modifier: 's/a/X/g' ('aabb' -> 'XXbb')\n";
	print "\n  A word on Quoting:\n";
	print "  Perl-special characters need proper treatment as they are evaluated:\n";
	print "    \$ needs to be escaped in the replace part, otherwise it is threaten as\n";
	print "       backreference or variable reference. In the search part, it only has\n";
	print "       its usual meaning (line-end) and needs escaping when literal\$ is meant.\n";
	print "       You can exploit this to use environment variables: 's/foo/$ENV{BAR}/'\n";
	print "    \@ needs to be escaped in the replace part, otherwise no match will occur.\n";

	print "\nRegular Expressions - special menaing of line-start and line-end patterns:\n";
	print "  For each attribute an empty string will be evaluated against the patterns.\n";
	print "  This gives ^ and \$ a special meaning and usually requires your special\n";
	print "  attention: you need to adjust your LDAP filter and/or use lookahead/-behind\n";
	print "  and/or capture patterns with backreferences to get the desired results:\n";
	print "    's/^/foo/'       Prepend 'foo' to any value AND add a distinct value 'foo',\n";
	print "                     regardless if there are other values.\n";
	print "    's/\$/foo/'       Same as above, but append to the end.\n";
	print "    's/^\$/foo/'      Only add 'foo' as distinct value to the attribute,\n";
	print "                     regardless if there are other values.\n";
	print "    's/^(?=.)/foo/'  Only prepend 'foo' to existing values (lookahead).\n";
	print "    's/(?<=.)\$/foo/' Only append 'foo' to existing values (lookbehind).\n";
	print "    's/^(.)/foo\$1/'  Like the lookahead example above using backreference.\n";
        print "    's/(.)\$/\$1foo/'  Like the lookbehind example above using backreference.\n";
	print "    's/^./foo/'      Beware: replace the first character with 'foo'.\n";
	print "    's/.\$/foo/'      Beware: replace the last character with 'foo'.\n";
	print "    's/.*/foo/'      Beware: replace all values AND add distinct value 'foo'.\n";
	
	print "\nAdding distinct values exclusively to empty attributes:\n";
	print "  The above rules applies to all entries found by the LDAP filter. If you want\n";
	print "  to handle only certain entries, you need to specify this in the LDAP filter.\n";
	print "  That is especially the case for adding distinct values to only-empty\n";
	print "  attributes which can only be accomplished using a combination like:\n";
	print "  $cmdname -r 'givenName=s/^\$/foo/' -f '(!(givenName=*))'\n";
	print "  This will only process entries whose givenName attribute is empty. The rule\n";
	print "  will then add 'foo' as distinct values to all found entries (regardless if\n";
	print "  values where present, which is in this case prevented by the filter).\n";

	print "\nUsage Examples: (parameters except -r ommited for better readability)\n";
	print "  $cmdname -r 'sn=s/foo//'\n";
	print "    -> remove 'foo' from surname ('myfoobar' -> 'mybar'; 'foo' -> '')\n";
	print "\n  $cmdname -r 'sn=s/^.*bar.*\$//'\n";
	print "    -> remove complete value if sn contains 'bar'\n";
	print "\n  $cmdname -r 'sn=s/^bar(.*)\$/\\1foo/'\n";
	print "    -> replace every sn that begins with 'bar' with the text behind\n";
	print "       'bar' followed by 'foo' ('bartest' -> 'testfoo')\n";
	print "\n  $cmdname -r 'mail=s/^\$/foo\\\@bar.org/' -f '(!(mail=*))'\n";
	print "    -> add mail adress 'foo\@bar.org' to entries that don't have one yet.\n";
	print "\n  $cmdname -r 'mail=s/^\$/foo\\\@bar.org/'\n";
	print "    -> add 'foo\@bar.org' as new additional mail address to all found entries\n";
	print "\n  $cmdname -r 'mail=s/\\.org\$/.de/' -r 'mail=s/^(.).+\\.(.+)\@/\$1.\$2@/'\n";
	print "    -> two rules for mail attribute:\n";
	print "       1. Transform all *.org mail addresses to *.de ones\n";
	print "       2. Transorm all names in format 'givenname.surname@...' to 'g.surname@...'\n";

	print "\nKeep the LDAP password secure:\n";
	print "  If you use the -p parameter to supply a password, the program will mask it so it\n";
	print "  will not show on the process list. However, this is still not entirely secure. If\n";
	print "  run interactively, you should type in the password (just omit -p) or pass it by\n";
	print "  reading it from file (e.g. 'cat passwordFile | $cmdname ...'), however be\n";
	print "  sure to also keep this file secure (proper access rights etc).\n";

	print "\nTroubleshooting:\n";
	print "  If you have problems with special characters (e.g. german umlauts),\n";
	print "  try to set your terminal to UTF8 and retry.\n";
	print "  If you find bugs, please report them to the bugtracker:\n";
	print "    https://github.com/hbeni/ldap-tools/issues\n";
}

# small utility function
# this will bail out early and thus only inspect half of the values on average
# call like 'in_array($attr_name, $needle, @haystack)'
sub in_array {
	my $attr_name = $_[0];
	my $needle    = $_[1];
	my @haystack  = @_[2..$#_];
	my $retVal    = 0;
	foreach my $curval (@haystack) {
		if ( attr_compare_equal($attr_name, $curval, $needle) ) {
			$retVal = 1;
			last;
		}
	}
	$retVal;
}

# small function to client-side compare attribute values
# call like 'attr_compare_equal($attr_name, $a, $b)'
# returns 1 if equal, 0 if not.
# Note that we do a case sensitive check here; replacements are made with
# "delete-then-add" so we can change cases in values even on case-insensitive attributes.
# If in the future other special comparisons arise, like needed decoding etc, we can implement
# this here using schema checks or regexp or some other magic.
sub attr_compare_equal {
	my $attr_name = $_[0]; # for future usage
	my $valA      = $_[1];
	my $valB      = $_[2];
	my $retVal    = 0;
	if ( "$valA" eq "$valB" )  { $retVal = 1; }
	$retVal;
}

