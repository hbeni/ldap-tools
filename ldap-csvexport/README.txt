ldap-csvexport.pl README
---------------------------

This is a brief description of ldap-csvexport.pl, a tool written in perl
that you can use to easily and quickly export LDAP entries into CSV format.


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
`ldap-csvexport.pl -h` which will print out basic usage and some extended
informations including usage examples.
Calling just ldap-csvexport.pl without parameters gives you the
shorter usage information.


III. Internals
The tool first connects and binds to the LDAP server you provide using
parameters. Then it searches with some LDAP filter that you provide
via the parameter -f. With -F you may specify a regular expression
that will filter entries in case the regexp matches on the DN, which may
be handy if a filter on attributes is not sufficient (like excluding
just one subtree of several others).
The parameter -a is used to tell ldap-csvexport.pl what attributes of
the found entries you want have to be exported in CSV.
For each found entry, the script will then print out all selected attributes
in the defined format (see parameters -1, -m, -q and -s to tune the CSV output).
ldap-csvexport.pl can deal with mutlivalued attributes. If several values are
found, they will be separated by some special string sequence.

Lets assume the following entry (LDIF notation, note the two values for
the mail-attribute):
    dn: cn=foo bar,dc=example,dc=com
    givenName: foo
    sn: bar
    mail: f.bar@example.com
    mail: foo.bar@example.com
    telephoneNumber: 1234567890

Running `ldap-csvexport.pl -a givenName,sn,mail` now, this will result in:
    "givenName","sn","mail"
    "foo","bar","f.bar@example.com|foo.bar@example.com"
I.e. all values of attribute "mail" is written to a single CSV-field where each
value of "mail" is separated by the pipe char.

As you have seen, the default behavior is that multivalued attributes are exported
with all values which is not always desired. You can use the '-1' parameter to
switch to single-value mode, where only the first attribute value will be printed.
You also may specify attribute flags in case you want to override single attributes
only, like: `ldap-csvexport.pl -a '[sv].mail,manager'` which will export all
managers but only the first mail adress. You can also do the opposite if you
specify -1 together with '[mv]' flags where you like to export all values.

You can request "magic" attributes to access additional features:
  -a dn      will export the full DN of the entry
  -a rdn     will export the base name of the entry
  -a pdn     will export the dn of the parent object
  -a fix=... will print the fixed string "...".
Example: Running `ldap-csvexport.pl -a givenName,fix=DN-Info:,rdn,pdn,dn` will result in:
    "givenName";"fix=DN-Info:";"sn";"mail"
    "foo";"DN-Info:";"cn=foo bar";"dc=example,dc=com";"cn=foo bar,dc=example,dc=com"

You can perform chained lookups for attributes using the dot-syntax (attr1.attr2).
This is useful in case you have DN references at the main entries but want to fetch
attributes from referenced entries (eg. at entry: 'manager: cn=foo,dc=example,dc=cno').
For example to retrieve the surname of the manager of the person, do: '-a manager.sn'.
Deep-chaining is possible in arbitary levels: to get the managers manager surname,
give: '-a manager.manager.sn'. In case there are reference errors or empty references,
the empty string will be returned to allow further processing of your request.
Please note that resolving the references requires an additional LDAP search operation
per reference given, so using references at huge search results or deep chaining results
in a significant prolonged program operation and possible more load on your LDAP server.
Note also the combination of chaining with multivalued reference attributes: it may be
possible that multiple 'manager' attribute values are present, but you only want to
export some attribute of the first one, like exporting all mail adresses of the first manager:
`ldap-csvexport.pl -a [sv]manager.mail` will do the trick.

A probably useful feature is the [#] flag which allows you to print the values number count
instead of the contents. Look at this real life example at a public test LDAP server which
retrieves the member count of all groups:
  ldap-csvexport.pl -H 'ldap://ldap.forumsys.com:389/dc=example,dc=com?ou,[#]uniqueMember,uniqueMember.uid?sub?(objectClass=groupOfUniqueNames)'
  "ou";"uniqueMember";"uniqueMember.uid"
  "mathematicians";"5";"euclid|riemann|euler|gauss|test"
  "scientists";"4";"einstein|galieleo|tesla|newton"
  "italians";"1";"tesla"


Try also `ldap-csvexport.pl -h` which gives some short advanced examples.

Have fun!
