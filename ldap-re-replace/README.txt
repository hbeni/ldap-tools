ldap-preg_replace.pl README
---------------------------

This is a brief description of ldap-preg_replace.pl, a tool written in perl
that you can use to change/add/delete values of attributes in a LDAP directory
service online (that is without LDIF-Files). Because it uses regular
expressions it is very powerful but remains easyly controllable.
It is able to process huge numbers of entries, only limited by processing
power and server limits.
It supports recent LDAP features like paging and requesting limits. You can
also create a LDIF change file containing the replacement operations.

Regular Expressions are a language to describe text patterns. With this you can
easily extract portions out of unknown text pieces or validate its syntax.
And one of the opportunitys is to search-and-replace using extended wildcards.
This will get very powerful once you reach the case that datafields are similar
in their construction but have variable content:
Assume you have the following strings: '1abc', '2defgh', '3i'.
If you now want to construct 'abc1', and 'i3' but not 'defgh2', then you can do
this manually (certainly not with several hundreds or thousands of strings!),
write a tool to do it or employ the power of RegExp. If you now consider those
strings stored as values of LDAP attributes, ldap-preg-replace is your tool!
The following oneliner expression solves this challenge: 's/([13](\w*))/$2$1/'.
It takes strings beginning with 1 or 3, followed by variable sized characters
and then reversing their order: With '1abc', $1=abc and $2=1.


Please also have a look to other related tools hosted on sf.net:
ldap-preg-replace:  Change entries in ldap online with regexp
ldap-searchEntries: Mass check existence / enrich of entries based on csv
ldap-collate:       Group and count entries by attributes
ldap-csvexport:     Easily export LDAP to abitary csv-formats
ldif-preg-replace:  Convert and modify LDIF files
csv2ldif2:          Convert arbitary CSV files to LDIF
ldif-extract:       grep-like filter for entries in LDIF


I. Prerequisites and installation

Installation is not neccessary. Just drop the perl script at your favorite
location (probably ~/bin/) and make it executable (chmod u+x). You may now
call it by typing ldap-preg-replace.pl to your shell.
If this does not work or if you are running windows, you can also call it
through the perl executable: perl ldap-preg-replace.pl (or perl.exe).

However, before you can run this program, you need:
  * PERL installed (perl.org)
  * PERL modules 'Net::LDAP' and 'Getopt::Long'. Both should be available
    in your linux distributions package archive, otherwise fetch them from
    CPAN (this applies also for windows users)



II. General invocation

Usage is very easy. Just call the script and provide the neccessary command
line parameters. To learn what parameters are available, call
`ldap-preg_replace.pl -h` which will print out basic usage and some extended
informations including usage examples.
Calling just ldap-preg_replace.pl without parameters gives you the
short version (usage information).
It is a good hint to make extensive use of the --dryrun option together with
--verbose and --sizelimit to develop your pattern and learn the tool.

If you use a LDAP-URL together with -H (--host), you can set the baseDN, scope
and filter (like -f/--filter, not like -F!) in one go (see the help for this).
This reduces the tools options to just two parameters, --host and --rule in
its simplest form, like:
ldap-preg-replace.pl --host 'ldap://foohost.org/cn=foo,dc=org??sub?(cn=*)'
                     --rule 'mail=/(.+)\.org/$1.com'



III. Internals

a) Common runtime explained
The tool first connects and binds to the LDAP server you provide using cmdline
parameters. Then it searches with some LDAP filter for entries.
Each found entry is then processed, that is, the rules defined by your
--rule option are applied to all their respective attribute values.
It is important that you consider the following, when you design your patterns:
To make the addition of values easily possible, the tool matches your rules on
a "virtual" empty string value in addition to all present values.
If you just want to append to present values, you need to take care to design
your pattern so it wont match the empty string. You may use the --verbose
switch (2+ times) to see this in action.

b) Filter and automatic filter tuning
When you use the -F option, the filter given will be used as-is.
If you supply the filter with -f or --filter (or as part of the LDAP-URL), the
tool will try to improve performance. It does this by enhancing your filter
with assertions for presence of at least one of the attributes specified in
your rules, eg.:
  ldap-preg-replace.pl -f '(cn=ABC*)' --rule 'mail=...' --rule 'sn=...'
will expand your filter to: '(&(cn=ABC*)(|(mail=*)(sn=*)))', thus finding
all entries with cn=ABC* and either mail or sn attribute filled.
This is usually no problem and good as long as you want to manipulate only
such entries. However if you want to add values to empty attributes and have
no rules requesting other attributes of such entries, you need to explicitely
design your LDAP filter so the entries are included. Some situations will
require you to disable this optimisation entirely by using the -F option.
If you only provide one single rule this has the side effect of only retrieving
entries with the attribute containing values. With several rules, the result is
not as clear, as already explained, but will be fine as long as your rules dont
match the empty-string (eg only manipulate existing values).

c) Paged searches
If you enable paged searching (which is the default unless you invoke '-P 0')
the tool will send a paged search request to the server. As soon as the server
sends entries as response, the tool will start processing them, saving runtime.



IV. Getting help

The tool provides you with further details and also with examples if you call
ldap-preg-replace.pl -h .

Regular Expressions have a somewhat cryptic syntax if you first see them.
For more information on this topic, feed your favorite search engine
with something like "perl regular expressions replace syntax".
A good idea may be to read http://perldoc.perl.org/perlretut.html.
Try also `ldap-preg_replace.pl -h` which gives some short examples for common tasks.

Have fun and e(nj|mpl)oy the power of regular expressions!
