ldif-preg-replace.pl README
---------------------------

This is a brief description of ldif-preg-replace.pl, a tool written in perl
that lets you easily and very flexible modify LDIF files.
Its usage is somewhat similar to the famous 'sed' command, especially
allowing it to be used as a modifier in a pipe, for example to
modify the output of a ldapsearch-command on the fly.


Please also have a look to other related tools hosted on sf.net:
ldap-preg-replace:  Change entries in ldap online with regexp
ldap-searchEntries: Mass check existence / enrich of entries based on csv
ldap-collate:       Group and count entries by attributes
ldap-csvexport:     Easily export LDAP to abitary csv-formats
ldif-preg-replace:  Convert and modify LDIF files
csv2ldif2:          Convert arbitary CSV files to LDIF
ldif-extract:       grep-like filter for entries in LDIF


TODOs:
- Probably allow to remove entire attributes with empty match.
  The line must be ommitted when doing so. Currently an empty
  line is printed instead, making the resulting LDIF-file corrupt.


I. Prerequisites and installing
Installation is not neccessary. Just make the file executable
if it is not already, or run the script through `perl`.
It runs entirely on perl core modules.


II. General
Usage is very easy. Just call the script and provide the neccessary
command line parameters. To learn what parameters are available, call
`ldif-preg-replace.pl -h` which will print out basic usage and some extended
informations including usage examples.
Calling just ldif-preg-replace.pl without parameters gives you the
shorter usage information.


III. Internals
The tool reads the input file (either given with -f, as second parameter or
STDIN via pipe or file redirection) line by line and applies your
specified replace pattern ("s/pattern/replace/").
When the program detects an attribute value that is base64 encoded, it
will decode this value before applying the regular expression.
When its done, it will reencode the value in base64 if contains unsafe chars.

Lets assume the following LDIF file, and say; you want to exchange the baseDN:
    dn: cn=foo bar,dc=example,dc=com
    givenName: foo
    sn: bar

Running `ldif-preg-replace.pl 's/dc=com/dc=de/' file.ldif` will result in:
    dn: cn=foo bar,dc=example,dc=de
    givenName: foo            ^^^^^ note the change!
    sn: bar

The regular expression is applied to the entire string, so you
can also alter attribute names easily.

Additionally, the expression is matched against the decoded value of the
attribute. In case you have base64 data in your ldif, the regexp will alter
the original value, not the base64 code (unless -d is given):
   'foobar' in base64 is: Zm9vYmFy
   `ldif-preg-replace.pl 's/foobar/barfoo/'` will result in 'barfoo' (YmFyZm9v).
You can use the swithes -e and -d to control de-/encoding behavior;
in the example activiating -e will disable encoding of "barfoo" so you can
read it in plaintext. -d will disable decoding of "foobar" (ie. "Zm9vYmFy"),
so the pattern will not replace anything here, giving back "Zm9vYmFy".
You should only use -d in case you explicitely want to match the base64-code.


Try also `ldif-preg-replace.pl -h` which gives some short advanced examples.

Have fun!
