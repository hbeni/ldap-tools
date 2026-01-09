ldap-searchEntries.pl README
---------------------------

This is a brief description of ldap-searchEntries.pl, a tool written in perl
that you can use to easily and quickly check if huge ammounts of entries
are present in an LDAP directory based on data from STDIN (as such,
the data source for the list can be arbitary).

In other words: For a given input list (like CSV), build a ldap-filter using
variables that get filled with the input data and execute a search for each
record.
The tool will tell you for each record, how many entries are found and,
optionally, enrich the data with data from the ldap server.



Please also have a look to other related tools :
ldap-preg-replace:  Change entries in ldap online with regexp
ldap-searchEntries: Mass check existence / enrich of entries based on csv
ldap-collate:       Group and count entries by attributes
ldap-csvexport:     Easily export LDAP to abitary csv-formats
ldif-preg-replace:  Convert and modify LDIF files
csv2ldif2:          Convert arbitary CSV files to LDIF
ldif-extract:       grep-like filter for entries in LDIF


TODOs:
- None at the moment, it should be feature complete already :)
  Please feel free to suggest new features via ths SF-Tracker.


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
`ldap-searchEntries.pl -h` which will print out basic usage and some extended
informations including usage examples.
Calling it without parameters gives you the short version (usage information).


III. Internals
The tool first connects and binds to the LDAP server you provide using
parameters. Then it reads STDIN and splits the values given using a provided
regexp (-s; defaults to blanks).
The split values are then parsed into the filter argument (-f):
each occurence of "%n" or "{%n}" is replaced by its position in the split result;
 given STDIN="one two three" (three elements and -s="\s"):
 (|(cn=foo%1*)(cn={%2}123))  =>  (|(cn=fooone*)(cn=two123)). "three" is discarded.
Note that %2 without the brackets ("cn=%2123") tries to fill the placeholder
2123 which is not available in the data. This produces an error message on STDERR.

The parsed filter is then used to search the directory you specified with the
-H, -u and -p parameters.
Each STDIN record is printed to STDOUT, followed by the search result. For each
entry matching the parsed filter, the DN is printed. If you queried attributes
(-a parameter) then also those are printed below the DN.
There is a separate CSV based output which instead first prints a header line
followed by the search results divided into two collums:
ARGS and number of found entries.

For usage examples call `ldap-searchEntries.pl -h`.

Have fun!
