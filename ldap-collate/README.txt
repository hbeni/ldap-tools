ldap-collate.pl README
---------------------------

This is a brief description of ldap-collate.pl, a tool written in perl
that you can use to easily and quickly count entries and group them by
an attribute present in an arbitary LDAP directory.


Please also have a look to other related tools :
ldap-preg-replace:  Change entries in ldap online with regexp
ldap-searchEntries: Mass check existence / enrich of entries based on csv
ldap-collate:       Group and count entries by attributes
ldap-csvexport:     Easily export LDAP to abitary csv-formats
ldif-preg-replace:  Convert and modify LDIF files
csv2ldif2:          Convert arbitary CSV files to LDIF
ldif-extract:       grep-like filter for entries in LDIF


TODOs:
  - Support for multiple attributes in list is still not implemented yet.
  - Please feel free to suggest new features via ths SF-Tracker.


I. Prerequisites and installing
Installation is not neccessary. Just make the file executable
if it is not already, or run the script through `perl`.
However, before you can run this program, you need:
  * PERL installed (perl.org)
  * PERL modules 'Net::LDAP' and 'Getopt::Std'. Both should be available
    in your linux distributions package archive, otherwise fetch them from
    CPAN (this applies also for windows users). As of the time this article
    was written, Getopt was already part of perls distribution.


II. General
Usage is very easy. Just call the script and provide the neccessary
command line parameters. To learn what parameters are available, call
`ldap-collate.pl -h` which will print out basic usage and some extended
informations including usage examples.
Calling it without parameters gives you the short version (usage information).


III. Internals
The tool first connects and binds to the LDAP server you provide using
parameters.
It then searches entires using the optionally given user filter.
The requested attriubute is read and the entry raises the counter for the
attribute values present. This results in a grouped list where each attribute
value tells how many entries contains this particular value; through the
whole of the list you also get knowledge of all distinct values present.
Optionally you can also print the matched entries DNs.

For usage examples call `ldap-collate.pl -h`.

Have fun!
