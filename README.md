Yet another LDAP toolbox
========================

This is a collection of small, but powerful LDAP and LDIF tools. They will help you with a lot of tasks like quickly manipulating huge datasets, or exporting data from directory servers like openLDAP, DirX Directory or ActiveDirectory.  
They are written in perl and thus platform independent, and generally shell terminal tools. Also they read from STDIN and write to STDOUT, which make them very nice to use in scripts and use piping to chain commands.

| LDAP Tool        | Description |
| ----------- | ----------- |
| `ldap-preg-replace` | Change entries in ldap online with regexp  |
| `ldap-searchEntries` | Mass check existence / enrich of entries based on csv |
| `ldap-collate` | Group and count entries by attributes |
| `ldap-csvexport` | Easily export LDAP to abitary csv-formats |

| LDIF Tool        | Description |
| ----------- | ----------- |
| `ldif-preg-replace` | Convert and modify LDIF files with regexp |
| `csv2ldif2` | Convert arbitary CSV files to LDIF |
| `ldif-extract` | grep-like filter for entries in LDIF |


Installation
------------
The are written in perl, so you can use them on Linux, Windows, and other platforms where perl is supported. You probably need to install some perl packages - the tool has the needed information in the source code header (perl will complain when there is something missing).  

Just download the box, unzip to a convinient place and call your selected tool.

The tools all support a `-h` option with syntax and usage information. Also, each tool comes with a Readme.txt.


History
-------
I wrote the tools one after another, over the succession of several years, because I always again had the need to do repetive and complicated LDAP stuff which I used to write specialized tools for.
It was so annoying to me that I decided that I want to generalize those usecases and did so, writing these tools. They are in use at a nearly daily basis since ever then, saving me thousands of hours.

They where originally hosted on SourceForge from 2007 to 2025.