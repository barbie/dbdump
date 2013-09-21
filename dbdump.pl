#!/usr/bin/perl -w
use strict;

my $VERSION = 0.03;

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
use IO::File;
use File::Path;
use File::Basename;
use Net::SCP;

# -------------------------------------
# Variables

my $fmt_file  = 'backups/%04d/%02d/%s-%04d%02d%02d.sql';

my %formats = (
    'mysql' => 'mysqldump -u %s --add-drop-table %s >%s',
    'pg'    => 'pg_dump -S %s %s -f %s -i -x -O -R'
);

my %compress = (
    'gzip'      => { cmd => 'gzip %s',     ext => '.gz'  }
    'zip'       => { cmd => 'zip %s',      ext => '.zip' }
    'compress'  => { cmd => 'compress %s', ext => '.Z'  }
);


# -------------------------------------
# Main Process

my $cfg = load_config();
process();

# -------------------------------------
# Functions

sub process {
    chdir($cfg->{LOCAL}{VHOST});

    my @files;
    my @sites   = grep { $cfg->{SITES}{$_}   } keys %{ $cfg->{SITES}   };
    my @servers = grep { $cfg->{SERVERS}{$_} } keys %{ $cfg->{SERVERS} };

    for my $site (@sites) {
        next    unless(-d $cfg->{$site}{path});

        if(!$formats{ $cfg->{$site}{fmt} }) {
            _log("WARNING: unknown db format [$cfg->{$site}{fmt}] for $site, skipping site");
            next;
        }

        if($cfg->{$site}{compress} && !$compress{ $cfg->{$site}{compress} }) {
            _log("WARNING: unknown compression format [$cfg->{$site}{compress}] for $site, skipping site");
            next;
        }

        my $db   = $cfg->{$site}{db};
        my @dt   = localtime(time);
        my $sql  = sprintf $fmt_file, $dt[5]+1900, $dt[4]+1, $db, $dt[5]+1900, $dt[4]+1, $dt[3];
        my $cmd1 = sprintf $formats{$cfg->{$site}{fmt}}, $DBUSER, $db, $sql;
        my $cmd2 = sprintf $compress{$cfg->{$site}{compress}}->{cmd}, $sql;
        mkpath(dirname($sql));

        my $archive;
        $archive = $sql . $compress{ $cfg->{$site}{compress} }->{ext}   if($cfg->{$site}{compress});

        if(-f $sql) {
            _log("WARNING: file [$sql] exists, will not overwrite, skipping site")
            next;
        } elsif($archive && - $archive) {
            _log("WARNING: file [$archive] exists, will not overwrite, skipping site") }
            next;
        }

        # create database dump file
        my $res = `$cmd1`;
        if($res) { 
            _log("ERROR: res=[$res], cmd=[$cmd1]");
            next;
        }

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

        push @files, $archive
    }

    return  unless(@servers);

    unless(@files) {
        _log("WARN: no files processed to transfer to other servers]");
        return;
    }

    # now to SCP to the remote servers
    for my $server (@servers) {
        if(my $scp = Net::SCP->new( $cfg->{$server}{ip}, $cfg->{$server}{user} )) {
            for my $source (@files) {
                $scp->mkdir(dirname($source));
                $scp->put($source,$source) or _log($scp->{errstr});
            }
        } else {
            _log("ERROR: Unable to connect to server [$cfg->{$server}{ip}]");
        }
    }
}

sub load_config {
    my (%configs,$settings);

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

    return \%configs;
}

sub _log {
    my $msg = shift;

    my $fh = IO::File->new('>>backups/dbdump.log')	or die "Cannot write to file [backups/dbdump.log]: $!\n";
	print $fh "$msg\n";
    $fh->close;
}

__END__

=head1 CONFIGURATION

The script runs using a configuration file residing in the same directory as 
the program, and named 'dbdump.ini'. The file should consist of three types of
sections.

=head2 Local Section

The Local section is mandatory and should include the entries DBUSER and VHOST.
The DBUSER should be the user set up to access the database via localhost
without requiring a password. VHOST is the base directory where the backups 
directory and local filestore will reside. An example of this section is below: 

  [LOCAL]
  DBUSER=dbuser
  VHOST=/var/www/

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
  compress=gzip

  [SITE2]
  path=/var/www/site2
  db=site2
  fmt=pg

As per the SERVERS section, the SITES section must list the sites you wish to
back up. These can then selectively enabled or disabled by setting to 1 or 0 
respectively. Only those sites listed and enabled in the SITES section will be
processed.

=head2 Database Formats

There are currently two database dump formats, 'mysql' and 'pg'. More may be
added in the future. Note these use system commands, so please ensure you have 
installed the appropriate binaries for your system.

=head2 Compression Formats

There are currently three compression formats, 'gzip', 'zip' and 'compress'. 
More may be added in the future. Note these use system commands, so please
ensure you have installed the appropriate binaries for your system.

=head2 File Name & Location

The configuration file name can be 'dbdump.ini' or '.dbdump.ini', and should be
stored in one of the following locations:

  * ./<file name>
  * <directory of .pl file>/<file name>
  * ~/<file name>

Precedence is as above. If you have multiple files in different locations, the
first found be the one that is used.

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
