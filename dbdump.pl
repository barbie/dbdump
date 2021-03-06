#!/usr/bin/perl -w
use strict;

my $VERSION = 0.05;

=head1 NAME

dbdump.pl - database remote backup application

=head1 SYNOPSIS

  perl dbdump.pl >>dbdump.log 2>&1

=head1 DESCRIPTION

From a configuration file, the application will attempt to dump the contents
of the database for each virtual host to a file. The file is then compressed
and if listed, copied to backup directories on the remote servers.

=cut

# -------------------------------------
# Library Modules

use Config::IniFiles;
use Getopt::Long;
use IO::File;
use File::Path;
use File::Basename;
use File::Find::Rule;
use Net::SCP;

# -------------------------------------
# Variables

my $fmt_file  = 'backups/%04d/%02d/%s-%04d%02d%02d.sql';

my %formats = (
    'mysql' => 'mysqldump -u %s --add-drop-table %s >%s',
    'pg'    => 'pg_dump -S %s %s -f %s -i -x -O -R'
);

my %compress = (
    'gzip'      => { cmd => 'gzip %s',     ext => '.gz'  },
    'zip'       => { cmd => 'zip %s',      ext => '.zip' },
    'compress'  => { cmd => 'compress %s', ext => '.Z'  }
);

my %options;

# -------------------------------------
# Main Process

my $cfg = load_config();
process();

# -------------------------------------
# Functions

sub process {
    _log("INFO: START") if($options{verbose});

    chdir($cfg->{LOCAL}{VHOST});

    my @files;
    my @sites   = grep { $cfg->{SITES}{$_}   } keys %{ $cfg->{SITES}   };
    my @servers = grep { $cfg->{SERVERS}{$_} } keys %{ $cfg->{SERVERS} };

    for my $site (@sites) {
        next    unless(-d $cfg->{$site}{path});

        _log("INFO: processing site '$site'")   if($options{verbose});

        my $dbuser = $cfg->{$site}{dbuser} || $cfg->{LOCAL}{DBUSER};
        unless($dbuser) {
            _log("WARNING: no database user for $site specified, skipping site");
            next;
        }

        my $fmt = $cfg->{$site}{fmt} || $cfg->{LOCAL}{fmt};
        unless($fmt && $formats{$fmt}) {
            _log("WARNING: unknown db format [$cfg->{$site}{fmt}] for $site, skipping site");
            next;
        }

        my $zip = $cfg->{$site}{compress} || $cfg->{LOCAL}{compress};
        if($zip && !$compress{$zip}) {
            _log("WARNING: unknown compression format [$cfg->{$site}{compress}] for $site, skipping site");
            next;
        }

        my $db   = $cfg->{$site}{db};
        my @dt   = localtime(time);
        my $sql  = sprintf $fmt_file, $dt[5]+1900, $dt[4]+1, $db, $dt[5]+1900, $dt[4]+1, $dt[3];
        my $cmd1 = sprintf $formats{$fmt}, $dbuser, $db, $sql;
        mkpath(dirname($sql));

        if($options{verbose}) {
            _log("INFO: fmt     = $fmt");
            _log("INFO: zip     = $zip");
            _log("INFO: dbuser  = $dbuser");
            _log("INFO: db      = $db");
            _log("INFO: sql     = $sql");
            _log("INFO: cmd1    = $cmd1");
        }

        my ($archive,$cmd2);
        if($zip) {
            $archive = $sql . $compress{ $zip }->{ext};
            $cmd2 = sprintf $compress{$zip}->{cmd}, $sql;

            if($options{verbose}) {
                _log("INFO: archive = $archive");
                _log("INFO: cmd2    = $cmd2");
            }
        }

        if($archive && -f $archive && !$options{force}) {
            _log("WARNING: file [$archive] exists, will not overwrite");
            push @files, $archive;
            next;
        }

        if(-f $sql && !$options{force}) {
            _log("WARNING: file [$sql] exists, will not overwrite");
        } else {
            # create database dump file
            my $res = `$cmd1`;
            if($res) { 
                _log("ERROR: res=[$res], cmd=[$cmd1]");
                next;
            }
        }

        _log("INFO: created sql dump")  if($options{verbose});

        unless($archive) {
            push @files, $sql;
            next;
        }

        # compress resulting file
        my $res = `$cmd2`;
        if($res) { 
            _log("ERROR: res=[$res], cmd=[$cmd2]");
            next;
        }

        _log("INFO: created archive")   if($options{verbose});

        push @files, $archive;
    }

    if(@servers) {
        if(@files) {
            # now to SCP to the remote servers
            for my $server (@servers) {
                _log("INFO: copying to server '$server'")   if($options{verbose});
                if(my $scp = Net::SCP->new( $cfg->{$server}{ip}, $cfg->{$server}{user} )) {
                    for my $source (@files) {
                        _log("INFO: copying file '$source'")    if($options{verbose});
                        $scp->mkdir(dirname($source));
                        $scp->put($source,$source) or _log($scp->{errstr});
                    }
                } else {
                    _log("ERROR: Unable to connect to server [$cfg->{$server}{ip}]");
                }
            }
        } else {
            _log("WARN: no files processed to transfer to other servers]");
        }
    }

    if($cfg->{LOCAL}{files} && $cfg->{LOCAL}{files} > 0) {
        my $ext = join( '|', map { $compress{$_}->{ext} } keys %compress );
        $ext =~ s/\./\\./g;

        _log("INFO: reducing files to $cfg->{LOCAL}{files} per site")   if($options{verbose});

        # now clean up
        my %files;
        @files = File::Find::Rule->file->name( qr/\.sql($ext)?$/)->in('backups');
        for my $file (sort @files) {
            if(-z $file && !$cfg->{LOCAL}{zero}) {
                _log("INFO: removing file '$file' (zero bytes)")    if($options{verbose});
                unlink $file; # zero bytes;
            } else {
                # store per site
                my ($db) = $file =~ m!.*/(\w+)-\d+\.sql(?:$ext)$!;
                if($db) { unshift @{ $files{$db} }, $file; }
            }
        }

        for my $db (sort keys %files) {
            next if(@{$files{$db}} <= $cfg->{LOCAL}{files});

            splice(@{$files{$db}},0,$cfg->{LOCAL}{files});
            for my $file (sort @{$files{$db}}) {
                _log("INFO: removing file '$file'") if($options{verbose});
                unlink $file;
            }
        }
    }

    _log("INFO: STOP")  if($options{verbose});
}

sub load_config {
    my (%configs,$settings);

    GetOptions(\%options, 'verbose', 'config=s', 'force');

    if($options{config}) {
        $settings = $options{config}    if($options{config});
    } else {
        # find config file
        for my $dir ('.', dirname($0), '~') {
            for my $ini ('.dbdump.ini','dbdump.ini') {
                my $file = "$dir/$ini";
                next    unless(-f $file);

                $settings = $file;
                last;
            }
            last    if($settings);
        }
    }

    if(!-f $settings) {
        _log("ERROR: No settings file [$settings] found. Please consult documentation (perldoc $0) for more information.");
        die;
    }

    my $c = Config::IniFiles->new( -file => $settings );
	unless(defined $c) {
        _log("ERROR: Unable to load settings file [$settings]");
        die;
    }

    for my $sect ($c->Sections()) {
        for my $name ($c->Parameters($sect)) {
            my @value = $c->val($sect,$name);
            next    unless(@value);
            if(@value > 1) {
                $configs{$sect}{$name} = \@value;
            } elsif(@value == 1) {
                $configs{$sect}{$name} = $value[0];
            }
        }
	}

    if($configs{FORMATS}) {
        for my $fmt (keys %{$configs{FORMATS}}) {
            $formats{$fmt} = $configs{FORMATS}{$fmt};
        }
        delete $configs{FORMATS};
    }

    if($configs{COMPRESS}) {
        for my $fmt (keys %{$configs{COMPRESS}}) {
            my ($ext,$cmd) = split('|',$configs{COMPRESS}{$fmt});
            next    unless($ext && $cmd);
            my @parts = split('%s',$cmd);
            next    unless(@parts == 2);

            $compress{$fmt}{ext} = $ext; 
            $compress{$fmt}{cmd} = $cmd; 
        }
        delete $configs{FORMATS};
    }

    $options{force} ||= $configs{LOCAL}{force};

    return \%configs;
}

sub _log {
    my $msg = shift;

    my @dt = localtime(time);
    my $dt = sprintf "%04d-%02d-%02dT%02d:%02d:%02d", $dt[5]+1900, $dt[4]+1, $dt[3], $dt[2], $dt[1], $dt[0];

    my $fh = IO::File->new('>>backups/dbdump.log')	or die "Cannot write to file [backups/dbdump.log]: $!\n";
	print $fh "$dt $msg\n";
    $fh->close;
}

__END__

=head1 COMMAND LINE OPTIONS

=head2 Configuration File

If you want to provide a configuration file from an alternative location, you
can do so by providing this on the command line as follows:

  perl dbdump.pl --config=/path/to/my/config.file

  # or

  perl dbdump.pl -c /path/to/my/config.file

=head2 Verbose Mode

Usually used for debugging purposes, you can enable the script to run in
verbose mode, which will provide slightly noiser logging messages. This can be
enabled on the command line as:

  perl dbdump.pl --verbose

  # or

  perl dbdump.pl -v
  
=head2 Force Mode

Normally SQL and archive files will not be recreated and overwrite existing 
files. However, adding the 'force' option will ensure that both files are
recreated. This can be enabled on the command line as:

  perl dbdump.pl --force

  # or

  perl dbdump.pl -f

Note that this can also be enabled in the configuration file.
  
=head1 CONFIGURATION

The script runs using a configuration file residing in the same directory as 
the program, and named 'dbdump.ini'. The file should consist of three types of
sections.

=head2 File Name & Location

The configuration file name can be 'dbdump.ini' or '.dbdump.ini', and should be
stored in one of the following locations:

  * ./<file name>
  * <directory of .pl file>/<file name>
  * ~/<file name>

Precedence is as above. If you have multiple files in different locations, the
first found be the one that is used.

=head2 Local Section

The Local section is mandatory and should include the entries DBUSER and VHOST.
The DBUSER should be the user set up to access the database via localhost
without requiring a password. VHOST is the base directory where the backups 
directory and local filestore will reside. An example of this section is below: 

  [LOCAL]
  DBUSER=dbuser
  VHOST=/var/www/
  fmt=mysql
  compress=gzip
  files=28
  zero=0
  force=0

The 'force' option, if set to a true value, will ensure SQL and archive files
are recreated if they already exist.

=head2 Clean Up

If 'files' is provided in the LOCAL section, this will be used to remove files
per site, keeping at most the number of files specified. 

Note that zero size files are automatically removed, unless the 'zero' field
is set to a positive value in the LOCAL section.

=head2 Database Formats

There are currently two database dump formats, 'mysql' and 'pg'. More may be
added in the future. Note these use system commands, so please ensure you have 
installed the appropriate binaries for your system.

Database dump formats can be specified in the LOCAL section, and will apply to
all sites, unless a format is explicitly specified in the site section.

You can also add your own Database Formats, or override exsiting ones, by
adding a FORMATS section:

  [FORMATS]
  mysql=mysqldump -u %s --add-drop-table %s >%s
  pg=pg_dump -S %s %s -f %s -i -x -O -R

Note that the '%s' are significant, and currently must be in the order of:

  1) user name with access to database
  2) database name
  3) output file

These may be made more configurable in the future.

=head2 Compression Formats

There are currently three compression formats, 'gzip', 'zip' and 'compress'. 
More may be added in the future. Note these use system commands, so please
ensure you have installed the appropriate binaries for your system.

Compression formats can be specified in the LOCAL section, and will apply to
all sites, unless a format is explicitly specified in the site section.

You can also add your own Compression Formats, or override exsiting ones, by
adding a COMPRESS section:

  [COMPRESS]
  gzip=.gz|gzip %s
  zip=.zip|zip %s
  compress=.Z|compress %s

The format of the assignment string is significant, and consist of the 
resulting file extension and the command used, separated by a '|'. If either
part of the string is blank, the format is ignored. 

The '%s' indicates the file name to be compressed. If this is also missing, or
more than one exists, the format will be ignored.

=head2 Servers Section

The Servers section indicates the servers you wish to copy the recently created
backup files to. You are expected to have set up the appropriate SSH keys and 
copied your public key to the server(s) you are copying to. You may have as 
many server entries as you wish, and the application will copy the backup files
to each. An example of this section is below: 

  [SERVERS]
  SERVER1=1

  [SERVER1]
  ip=127.0.0.1
  user=username

The 'SERVERS' section must list the servers you wish to access. These can then
selectively enabled or disabled by setting to 1 or 0 respectively. Only those
servers listed and enabled in the SERVERS section will be processed.

=head2 Sites Section

The sites which you require backing up, are all listed in the Sites section.
Each site is listed with its directory path, database name and the type of 
database currently used to store the content of the site. Note that only mysql
(mysql) and postgresql (pg) are support at the moment. An example of this 
section is below: 

  [SITES]
  SITE1=1
  SITE2=0

  [SITE1]
  path=/var/www/site1
  db=site1
  fmt=mysql
  compress=zip

  [SITE2]
  path=/var/www/site2
  db=site2
  fmt=pg
  dbuser=someoneelse

As per the SERVERS section, the SITES section must list the sites you wish to
back up. These can then selectively enabled or disabled by setting to 1 or 0 
respectively. Only those sites listed and enabled in the SITES section will be
processed.

Note that the 'dbuser' will override the DBUSER specified in the LOCAL section,
if included in the respective site seciton.

=head1 AUTHOR

Barbie, <barbie@missbarbell.co.uk> for
Miss Barbell Productions, L<http://www.missbarbell.co.uk/>

=head1 COPYRIGHT & LICENCE

  Copyright (C) 2007-2013 Barbie for Miss Barbell Productions

  This software is released as free software; such that you can redistribute
  it and/or modify it under the terms as the Artistic License v2.0, a copy 
  of which is included with this distribution.

=head1 DISCLAIMER OF WARRANTY

BECAUSE THIS SOFTWARE IS LICENSED FREE OF CHARGE, THERE IS NO WARRANTY
FOR THE SOFTWARE, TO THE EXTENT PERMITTED BY APPLICABLE LAW. EXCEPT WHEN
OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES
PROVIDE THE SOFTWARE "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER
EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE
ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE SOFTWARE IS WITH
YOU. SHOULD THE SOFTWARE PROVE DEFECTIVE, YOU ASSUME THE COST OF ALL
NECESSARY SERVICING, REPAIR, OR CORRECTION.

IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING
WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MAY MODIFY AND/OR
REDISTRIBUTE THE SOFTWARE AS PERMITTED BY THE ABOVE LICENCE, BE
LIABLE TO YOU FOR DAMAGES, INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL,
OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OR INABILITY TO USE
THE SOFTWARE (INCLUDING BUT NOT LIMITED TO LOSS OF DATA OR DATA BEING
RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD PARTIES OR A
FAILURE OF THE SOFTWARE TO OPERATE WITH ANY OTHER SOFTWARE), EVEN IF
SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF
SUCH DAMAGES.

=cut
