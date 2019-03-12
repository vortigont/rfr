#!/usr/bin/env perl

# Perl script to add rTorrent fast resume data to torrent files.
#
# see --help for details


use warnings;
use strict;
use Getopt::Long 2.25 qw(:config gnu_getopt);
#use Convert::Bencode qw(bencode bdecode);
use Convert::Bencode_XS qw(bencode bdecode);
#use Convert::Bencode_XS qw(:all);
use File::Basename;
use File::Path qw(make_path);
use Data::Dumper;
use Pod::Usage;

my $VERSION = "1.0.2";

#var for torrent data
my $tdata;
# chunks in torrent
my $chunks;
my $chunks_done;
my $tsize;
my $debug = 0;

my $man = 0;
my $help = 0;

# options parsing
my %opt = ();
GetOptions(\%opt,
	    'base|b=s',
	    'debug|D+' => \$debug,
	    'destination|d=s',
	    'help|h' => sub{ &help() },
	    'man' => sub{ &help('man') },
	    'old-version|o',
	    'remove-source|r',
	    'session|s=s',
	    'unfinished|u',
	    'verbose|v',
	    'coerce|c',
	    '<>' => \&do_torrent) or &help();


&help() unless %opt;

&fix_session($opt{'session'}) if $opt{'session'};

sub help {
    my $verb = shift;
    print "\nrfr.pl - an rtorrent fast resumer, version $VERSION\n\n";

    $verb ? pod2usage(-noperldoc=>1, -verbose => 2, -exitval => 0) : pod2usage(1);
    exit(1);
}

sub init {
    #ugly hack
    $opt{'verbose'} = 1 if $debug;

    print STDERR (join("|",@ARGV),"\n") if $debug;
	$Convert::Bencode_XS::COERCE = 0;
}

# process a single torrent
sub do_torrent {
    my $tfile = shift;

    &init();

    unless ( -e $tfile ) { print "No input file specified or file not found\n"; &help();  }

    #base is a mandatory
    unless  ( $opt{'base'} ) { print "Base dir (-b option) is a mandatory!\n"; return undef; }

    #load torrent file
    $tdata = &load_file($tfile) or return undef;

    #check if basepath is valid, contains any data to resume. Set rtorrent directory, so we'll need it later
    unless ( $tdata->{'rtorrent'}{'directory'} = &chk_basedir($opt{'base'}) ){
		print "Base path is wrong, aborting...\n"; return undef;
    }

    unless ( &resume() ) {
		print "Something went wrong when resuming $tdata->{'info'}{'name'}\nTry verbose mode to see more info\n";
		return undef;
    }

	#print "Dumping resumed torrent structure:\n" if $debug;
    #print Dumper ($tdata) if $debug;
	print "Dumping resumed torrent structure:\n" if $opt{'verbose'};
	print Dumper ($tdata) if $opt{'verbose'};

    # save to the sourse file if destination is not set
    $opt{'destination'} = $tfile unless $opt{'destination'};

    print "Destination - $opt{'destination'}\n";

    #I don't care about basename's last element may not be a file
    # if I was able to load it recently than it must be a file
    $opt{'destination'} .= basename($tfile) if chkdir(\$opt{'destination'});
    &savetofile( $tdata, $opt{'destination'} ) or return undef;

    #hope no one will set -d to the source dir and -r simultaneously :)
    if ( $opt{'remove-source'} && $opt{'destination'} ne $tfile   ) {
	unlink $tfile or print "Can't remove sorce file $tfile: $!\n";
    }
}


sub fix_session {
    my $dir =  shift;

    if ( $opt{'unfinished'}  ) { 
	print "Sorry, but missing files resuming with session dir is not implemented yet\n";
	print "Only completed torrents will be resumed\n";
	$opt{'unfinished'} = 0;
    }

    &chkdir(\$dir);

    chdir $dir or die "Cannot chdir to session directory $dir: $!\n";

    #check for lock file
    if ( -e "rtorrent.lock") { die ("ERROR: rtorrent lock file exists! Make sure your rtorrent is not running before working with session dir\n") }

    my @torrents = glob("*.torrent");

    foreach ( @torrents ) {

	my $torrent = $_;

	print "\n====\nProcessing file $torrent\n" if $opt{'verbose'};


	$tdata = &load_file($torrent);
	if ( not  $tdata ) { print "WARNING: Can't load $_\n"; next; }
	
	#new version of rtorrent stores its data in separate files
	unless ( $opt{'old-version'} ) { 
	    unless ( &load_rtdata($torrent) ) {
		print "WARNING: Can't load rtorrent data for $_\n"; next;
	    }
	};

        if ( defined $tdata->{'rtorrent'}{'complete'} && $tdata->{'rtorrent'}{'complete'} == 1 ) {
	    print "This torrent is finished\n" if $opt{'verbose'}; next;
	}

	#check if basepath is valid, contains any data to resume
	unless (  &chk_basedir($tdata->{'rtorrent'}{'directory'}) ) {
	    print "Base path is wrong, aborting...\n" if $opt{'verbose'}; next;
	}

	#try resume this torrent
	unless ( &resume() ) {
	    print "Something went wrong when resuming $tdata->{'info'}{'name'}\nTry verbose mode to see more info. Moving to next file\n";
	    next;
	}

	#save session file
	&savertsession($torrent);
    }

}

#returns bdecoded data or undef if file is broken or not readable
sub load_file {
    my $file = shift;

    unless (open(FP, $file)) { print "Could not open file $file: $!"; return undef; }

    print "Loading file - $file\n" if $opt{'verbose'};
    my $data;
    local $/=undef;
    binmode(FP);
    {
	$data = bdecode(<FP>);
	# or die "Can't decode bencoded data\n";
    }
    close(FP);

    print "Torrent $data->{'info'}{'name'}\n" if (defined $data->{'info'}{'name'} && $opt{'verbose'});
	#print "Loaded torrent structure:\n" if ($debug);
    #print Dumper($data) if ($debug);
	print "Loaded torrent structure:\n" if $opt{'verbose'};
    print Dumper($data) if $opt{'verbose'};


    return $data;
}

# sub getfiles checks torrent data for errors, makes basic calculations and
# returns ref to a list of all files in torrent
sub getfiles {
    my $t = shift;

    my $psize;

    unless (ref $t eq "HASH" and exists $t->{'info'}) { print "No info key.\n"; return undef; }

    unless ( $psize = $t->{'info'}{'piece length'} ) {print "No piece length key.\n"; return undef; }

    my @files = ();
    $tsize = 0;
    if ( &is_multi() ) {
		print "Multi file torrent: $t->{'info'}{'name'}\n" if $opt{'verbose'};
		for (@{$t->{'info'}{'files'}}) {
			push @files, join '/', @{$_->{'path'}}; 
			$tsize += $_->{'length'};
		}
    } else {
	  print "Single file torrent: $t->{'info'}{'name'}\n" if $opt{'verbose'};
	  @files = ($t->{'info'}{'name'});
	  $tsize = $t->{'info'}{'length'};
    }

    $chunks = &chunks($tsize,$psize);
    print "Total size: $tsize bytes; $chunks chunks; ", @files . " files.\n" if $opt{'verbose'};

    unless ( $chunks*20 == length $t->{'info'}{'pieces'} ) { print "Inconsistent piece information!\n"; return undef;}

    return \@files;
}


sub resume{

    
    my $files;
    unless ( $files = &getfiles($tdata) ) { print "WARNING: Can't get file list from torrent\n"; return undef; };

    my $d = $tdata->{'rtorrent'}{'directory'} . '/';

    
    my $ondisksize = 0;
    my $boffset = 0;


    for (0..$#{$files}) {

		my @fstat = -f "$d${$files}[$_]" ? stat "$d${$files}[$_]" : () ;

		#print "On-disk file size - " . $fstat[7] . "\n" if ($debug > 1);

		#process non-existent/empty files
		unless ( $fstat[7] ) {
			# fixme: partial session support
			# not $tdata->{'libtorrent_resume'}{'files'}["$_"]{'priority'} ) {

			print "File not found or size is 0: $d${$files}[$_]\n" if $opt{'verbose'};

			# resume fails here if we were not requested to check for missing files
			return undef unless $opt{'unfinished'};

			#marks chunks for this file as missing in chunks bitvector
			&recalc_bitfield( $boffset, $tdata->{'info'}{'files'}[$_]{'length'} );

	        my($filename, $dirpath, $suffix) = fileparse("$d${$files}[$_]");

		    #create nonexistent files
	  		unless ( -f "$d${$files}[$_]" ) {
				print "Creating zero byte file: $d${$files}[$_]\n\n" if $opt{'verbose'};

				# recreate dir path if missing
				unless ( -d $dirpath ) {
					make_path($dirpath) or return undef
				}

				open(FILE,">>$d${$files}[$_]") or die "Can't create file $d${$files}[$_]";
				close(FILE);

				#refresh fstat for the new file
				@fstat = stat "$d${$files}[$_]" or return undef;
			}


			$tdata->{'libtorrent_resume'}{'files'}[$_] = { 'mtime' => $fstat[9], 'completed' => 0 };
			$boffset += $tdata->{'info'}{'files'}[$_]{'length'};
			next;
		}

		#just a precaution, check if file's sizes match
        if ( &is_multi() ) {
	  		$boffset += $tdata->{'info'}{'files'}[$_]{'length'};
	  		next unless $tdata->{'info'}{'files'}[$_]{'length'} == $fstat[7];
		} else { 
	  		$boffset += $tdata->{'info'}{'length'};
	  		next unless $tdata->{'info'}{'length'} == $fstat[7];
		}

		$ondisksize += $fstat[7];
		$tdata->{'libtorrent_resume'}{'files'}[$_] = { 'mtime' => $fstat[9], 'completed' => 1 };
    };

    # resume failed if ondisk size = 0 (no files to resume actualy) or
    # ondisk size doens't match sum off all files in torrent and we were not requested to resume missing files
    if ( defined $opt{'unfinished'} && $opt{'unfinished'} != 1 && $ondisksize != $tsize ||  $ondisksize == 0 ) {
		print "Oops! Files size verification failed\n";
		print "Either not all files present or nothing to resume at all\n";
		print "In torrent size = $tsize,\t on-disk size = $ondisksize\n" if $opt{'verbose'};
		return undef;
    }

    my $chunks_done = &chunks($ondisksize,$tdata->{'info'}{'piece length'});
    print "\nResume summary for torrent $tdata->{'info'}{'name'}:\n$chunks_done out of $chunks chunks done\n";

    #set some vars in torrent
    $tdata->{'rtorrent'}{'chunks_wanted'} = $chunks - $chunks_done;
    $tdata->{'rtorrent'}{'chunks_done'} = $chunks_done;
    $tdata->{'rtorrent'}{'complete'} = ($chunks_done != $chunks) ? 0 : 1;
    $tdata->{'libtorrent_resume'}{'bitfield'} = $chunks unless ($chunks_done != $chunks);
    return 1;
}


#loads additional data for the new rtorrent versions to the global array
#returns 1 if success, 0 otherwise
sub load_rtdata {
    my $file = shift;
    $tdata->{'libtorrent_resume'} = &load_file($file . '.libtorrent_resume') or return 0;
    $tdata->{'rtorrent'} = &load_file($file . '.rtorrent') or return 0;
    return 1;
}

# saves bencoded data to the session
sub savertsession {
    my $file = shift;

    if ( $opt{'old-version'} ) {
	savetofile($tdata, $file) or return undef;
    }
    else {
	#save libtorrent_resume
	savetofile($tdata->{'libtorrent_resume'}, $file . '.libtorrent_resume') or return undef;
	savetofile($tdata->{'rtorrent'}, $file . '.rtorrent') or return undef;
    }
    return 1;
}

# saves bencoded data to file
# args - reference to a data to bencode
#      - file name with full path
sub savetofile {
    my $data = shift;
    my $file = shift;

    unless ( open(FP, ">$file") ) { print "Could not open file $file for writing:\n $!"; return undef; }
    print "Saving to file $file\n" if $opt{'verbose'};
    my $content = bencode $data;

    binmode(FP);
    print FP $content;
    close(FP);

    return 1;
}


## Sub chkdir
# gets link to a dir and adds trailing slash if missing
# returns empty string if link path is not a dir or dir path string otherwise
sub chkdir {
    my $dirlink = shift;
    return '' unless -d $$dirlink;
    $$dirlink .= "/" unless $$dirlink =~ m#/$#;
    return $$dirlink;
}

sub recalc_bitfield {
    my $offset = shift; my $size = shift;

    my $bf; 		#bitfield vector
    my $x;		#mode of operation 0 - for new torrents, 1 - for session
    my $fill;		# not x actualy

    $x = $opt{'session'} ? 0 : 1; $fill = $x ? 0 : 1;

    #init vector
    if ( not defined $tdata->{'libtorrent_resume'}{'bitfield'} ) {
		#my $vlength = int($chunks / 8 + 1);
		$bf = $x x $chunks;
    } else {
		$bf = unpack("B$chunks", $tdata->{'libtorrent_resume'}{'bitfield'});
    }

    my $blkoffset = &chunks($offset, $tdata->{'info'}{'piece length'}) - 1;
    my $missingchunks = &chunks($size + $offset, $tdata->{'info'}{'piece length'}) - $blkoffset;

    print "Chunk offset: $blkoffset, missingchunks: $missingchunks\n" if $debug;
    substr $bf, $blkoffset, $missingchunks, $fill x $missingchunks;


    print "BF length - " . length($bf) . "\n" if ($debug > 1);
    print "Chunk map:\n" . join(':', unpack("(A8)*", $bf)) . "\n===\n" if ($debug > 1);

    $tdata->{'libtorrent_resume'}{'bitfield'} = pack("B$chunks", $bf);

    return 1;
}

sub chunks {
    my $length = shift;
    my $chsize = shift;
    return int($length / $chsize + 1);
}

#checks the base path so we can find out if there is anything to resume
#returns path suitable to put in rtorrent->directory option or undef if any error
sub chk_basedir {
    my $path = shift;

    unless ( &chkdir(\$path) ) { print "Base $path is not a dir\n" if $opt{'verbose'}; return undef; }

    if ( &is_multi() ) {
		#in session torrents this path is already set
		$path = $path . $tdata->{'info'}{'name'} unless $opt{'session'};

		my $dh;
        #base dir for multifile  torrent must be at least not empty or we got nothing to do here
		unless ( opendir($dh, $path) ) { print "Can't open dir $path, $!\n"; return undef; }
		unless ( scalar(grep( !/^\.\.?$/, readdir($dh))) ) { print "Directory $path is empty\n";  return undef; }
    } else {
	unless ( -e $path . $tdata->{'info'}{'name'} ) {
	    print "No file under the base path so nothing to resume here\n" if $opt{'verbose'};
	    return undef;
	}
	#chop / from &chkdir function
	chop $path;
    }

    return $path;
}

sub is_multi {
     return exists $tdata->{'info'}{'files'};
};

# no code after this mark

__END__

=head1 NAME

rfr.pl is an rtorrent fast resumer. A script to add fast resume data to torrent files used by rtorrent.


=head1 DESCRIPTION

This script is intended to add fast resume data to rtorrent, so you don't need to hash-recheck all data if for some reason you are sure that
your data is exactly the same as referenced in torrent file.
Initialy it was based on rtorrent_fast_resume.pl by Josef Drexler http://libtorrent.rakshasa.no/downloads/rtorrent_fast_resume.pl
but later was completely rewriten to add more nice features and options.

This version supports:

 - extended command line options processing and features
 - processing multiple torrents from one command
 - resuming torrents with missing files (yep, it's nice!)
 - automated rtorrent session files resuming

=head1 OPTIONS

    rfr.pl [options] file ...
    rfr.pl [options] -s|--session <path>

    Options:
    -b, --base	<path>		Base directory to look for data files
    -D, --debug			debug output. WARNING! This will produle a lot of output including bencoded data dump,
				it's stongly advised to redirect STDOUT to a file, so it will not trash you terminal.
				Specify twice to produce even more debug output, including bitfield vector for each file.
    -d, --destination <path>	destination dir|file to save resumed torrent file
    -h, --help	  		brief help message
    --man        		full documentation
    -o, --old-version		use old rtorernt session format with all data in one file (for rtorrent <8.9)
    -r, --remove-source		remove source torrent file if resume was successful
    -s, --session <path>	resume all torrents in rtorrent session directory under <path>
    -u, --unfinished		check for missing files and resume partialy downloaded torrent
    -v, --verbose		be more verbose about what's going on there
    -c, --coerce		serialize (\d+) strings as integers (may corrupt torrents with digits-only directory/file names, like '\dir\123\name\somefile' )

    [file]			torrent file to resume

    See --man help page and examples section for more info.

=head1 Command Line Options, an Usage

ATTENTION! Please make a backup copies of your torrent files before any actions!

To resume single torrent file you need to specify at least -b for the base dir and path to the torrent file itself.
If <path> is specified with -d  (the destination) option, than this path will be used to save resulting torrent file.
If <path> is a dir, than original file name will be used as a new torrent file name under the path. If -d is not
given rfr will OVERWRITE original file itself. YES! Without any warnings! So either make a backup of your torrent
file or specify another destination.
If <path> is a file name under the valid dir than it will be used as a target filename to save resumed torrent.
If this file is already exist under this path it will be overwritten!

You can mix all options together or repeat it several times to process more than one torrent at once.
See examples for more info.

=head1 Resume partialy downloaded torrents

This feature will allow to resume torrents with some files missing from torent. So later you need to download
only those files missing and don't need to rehash the whole torrent.
Most usefull case for this is tv-shows downloading when the episodes released one by one. And each time you
download a new torrent with only one episode added you have to rehash all previous ones. Very annoing when it
comes to 20 episodes 3Gigs each. Not any more! With -u flag rfr will check if any files from torrent is
missing in the base dir and will add instructions to rtorrent to download only missing chunks from torrent.

!!!ATTENTION!!!
This will work only for missing files! Not for partialy downloaded files!!! All partialy
downloaded files will be marked as 100% finished if their size is equal to the value specified in torrent.
So you will never be able to finish you download actually until you rehash you torrent anyway to resume
partialy downloaded files. This option is ment for resuming disabled, missing or new files only.
Don't use it for unfinished torrents with partialy downloaded files!
When resuming rfr will create zero byte size files for every missing file in the base dir so rtorrent will
fill them with data later on.

See examples for more info how to use it.

=head1 Session directory resuming

Under some circumstatces rtorrent can loose it's session data state marking some torrents as 0%
completed, so you need to rehash tons of data to seed it again. Don't ask me why and when this happens...
a network share with your Petabyte storage disconnects when a janitor do his daily sweep or you dog pulls
the plug out of server just as soon as you almost finished downloading full LOST BlueRay edition, whatever...
it happens from time to time. Even one time rehashing a couple Ters of data could spoil you a day.

--session <path> option will help you to resume all torrents of your current rtorrent state

It will read all files in rtorrent session directory under <path> and resume all data based on information
in session state. So no basedir or other options required. Only torrents with correctly specified 
Base Path Directory in rtorrent will be resumed. All incomplete, partialy downloaded or torrents with
incorrect basedir will be ignored. So if you moved your files anywhere and rtorrent missed it, you must
setup correct basedir in rtorrent first. Use ctrl-o in console or webui, set the basedir, quit rtorrent
and than resume session dir.

A special option --old-version indicates that you use old versions of rtorrent. New versions use separate
files for resume data in session dir. I don't remember when this happened exactly, check you session dir
for  *.rtorrent *.libtorrent_resume files. If those are missing than you must specify --old-version option.
Don't forget to quit rtorrent first, rfr will refuse to run if it finds rtorrent lock file.

			    !!! WARNING !!!

Needless to say how backup of a session dir is important before making resume!!! If anything happens you
will loose everything!!! You've been warned!


=head1 EXAMPLES

* Resume a single torrent file and overwrite source file with file with resume info

    ./rfr.pl -b /opt/distro/linux ~/torrents/ubuntu11.torrent

* Resume a single torrent file and put resulting file under another name to the rtorrent watch dir

    ./rfr.pl -b /opt/distro/bsd -d ~/rtorret/watch/freebsd9_i386.torrent /tmp/some.torrent

* Resume multiple torrents with different basepathes, put resulting files with their original
    names under different rtorrent watch dirs and remove source torrent files

    ./rfr.pl -r -d ~/rtorret/watch -b /opt/distro/bsd /tmp/some.torent /tmp/anotherbsd.torent \
    -b /opt/distro/linux ~/torrents/ubuntu11.torrent \
    -d ~/rtorret/anotherwatch -b /opt/movies /tmp/somemovie.torent

* Resume tv-show torrent with new episodes added and see how much of it we saved :)
    put a torrent to the watch dir

    ./rfr.pl -vub /opt/tvshows/house.m.d.s08/ -d ~/rtorrent/watchtv ~/newtorrents/house.m.d.s08e1-8.torrent

* Resume rtorent session dir after something bad happened,
    assume we have rtorren 8.6

    ./rfr.pl -vo --session ~/rtorrent/session/


Don't forget about the backups anyway!!!


=head1 AUTHOR

Emil Muratov <gpm@hotplug.ru> (c) 2012

Based on code rtorrent_fast_resume.pl by Josef Drexler
http://libtorrent.rakshasa.no/downloads/rtorrent_fast_resume.pl

=head1 COPYRIGHT AND DISCLAIMER

Copyright (c) 2012 Emil Muratov

This program is free software; you can redistribute it and/or
modify it under the terms of "Simplified BSD License" or "FreeBSD License"

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; See the Simplified BSD License for more details.


=cut

