ldif-extract.pl README
---------------------------

This is a brief description of ldif-extract.pl, a tool written in perl
that you can use to extract selected entries of LDIF files. LDIF files
are human readable contents of LDAP directorys in file format.

It features grep-like behavior but acts on whole LDIF-entries, meaning
that if a match occur, the whole entry is printed. It can deal with
base64 encoded attributes and features some nice selection features.


Please also have a look to other related tools hosted on sf.net:
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
  * PERL installed (perl.org), in case you use linux, perl
    is most probably already ready to use.


II. General
Usage is very easy. Just call the script and provide the neccessary
command line parameters. To learn what parameters are available, call
`ldif-extract.pl -h` which will print out basic usage and some extended
informations including usage examples.

Its return codes are compatible to the grep program and its invocation
is similar, making it a good piece of software to use in piping like you
would otherwise with grep.


III. Internals
The tool reads LDIF content from STDIN (or a file you supplied) and
looks if one of your specified match conditions is satisfied.
If so, it will print the whole entry to STDOUT.
Please see `ldif-extract.pl -h` for more usage examples and details.


Have fun!
