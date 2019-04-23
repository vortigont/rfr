#!/usr/bin/env perl

# Perl script to add rTorrent fast resume data to torrent files.
#
# see --help for details


use warnings;
use strict;
use Getopt::Long 2.25 qw(:config gnu_getopt);
use Convert::Bencode_XS qw(:all);
use File::Basename;
use File::Path qw(make_path);
use File::Copy qw(copy);
use Data::Dumper;
use Pod::Usage;
use Digest::SHA1 qw(sha1_hex);

use constant CHUNK_HASH_SIZE => 20;

my $VERSION = "1.1.0";

#var for torrent data
my $tdata;
# chunks in torrent
my $chunks;
my $chunk_size;
my $tsize;
my $debug = 0;

my $man = 0;
my $help = 0;

# by default do coerce on bencode/decode
my $coerce = 1;

# options parsing
my %opt = ();
GetOptions(\%opt,
	    'base|b=s',
	    'debug|D+' => \$debug,
	    'destination|d=s',
		'dump=s' => \&tdump,
		'force|f',
	    'help|h' => sub{ help() },
	    'man' => sub{ help('man') },
	    'old-version|o',
	    'remove-source|r',
	    'session|s=s',
	    'unfinished|u',
	    'verbose|v',
	    't2r=s',
		'tied|t',
	    '<>' => \&do_torrent);


help() unless %opt;

if ( $opt{'t2r'} ){
    #dst is a mandatory
    unless ( chkdir(\$opt{'destination'}) ) { print "Destination dir (-d option) is a mandatory!\n"; exit 1; }
    unless ( chkdir(\$opt{'t2r'}) ) { print "--t2r must be a transmission session dir\n"; exit 1; }
    t2r($opt{'t2r'}, $opt{'destination'});
    exit 0;
}

fix_session($opt{'session'}) if $opt{'session'};

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
}

# process a single torrent
sub do_torrent {
    my $tfile = shift;

    &init();

    unless ( -e $tfile ) { print "No input file specified or file not found\n"; &help();  }

    #base is a mandatory
    unless  ( $opt{'base'} ) { print "Base dir (-b option) is a mandatory!\n"; return undef; }

    #load torrent file
    load_file($tfile, \$tdata, $coerce) or return undef;

	#check for coerce data
	$coerce = coercechck(\$tdata, $tfile);

    #check basepath
    my $chkpath = $opt{'session'} ? $tdata->{'rtorrent'}{'directory'} : $opt{'base'};

    my $infohash = torrent_check($tdata, $chkpath) or return undef;

    unless ( resume($tdata, 1) ) {
		print "Something went wrong when resuming $tdata->{'info'}{'name'}\n";
		print "Try verbose mode to see more info\n" unless $opt{'verbose'};
		return undef;
    }

	print "Dumping resumed torrent structure:\n" if $debug;
	print Dumper ($tdata) if $debug;

	if (defined $coerce) {
      # save to the sourse file if destination is not set
	  $opt{'destination'} = $tfile unless $opt{'destination'};

  	  print "Destination - $opt{'destination'}\n";

  	  #I don't care about basename's last element may not be a file
  	  # if I was able to load it recently than it must be a file
  	  $opt{'destination'} .= basename($tfile) if chkdir(\$opt{'destination'});
  	  savetofile( $tdata, $opt{'destination'}, $coerce ) or return undef;

	} else {
	##save "fuzzy" torrents via session format
		$opt{'destination'} = dirname($tfile) unless chkdir(\$opt{'destination'});
		chkdir(\$opt{'destination'}) or return undef;

		print "Saving session for infohash: $infohash\n";
		print "Pls copy files prefixed $infohash into rtorrent session dir and restart rtorrent to pick 'em up\n";
		my $dst_file = $opt{'destination'} . $infohash . '.torrent';
		unless (copy("$tfile", "$dst_file" )) { print "File copy failed, skip\n"; return undef; }

		#save session file
		&savertsession($dst_file) or return undef;
	}

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


	unless (load_file($torrent, \$tdata, $coerce)) { print "WARNING: Can't load $_\n"; next; };

	#new version of rtorrent stores its data in separate files
	unless ( $opt{'old-version'} ) { 
	    unless ( load_rtdata($torrent, \$tdata) ) {
		print "WARNING: Can't load rtorrent data for $_\n"; next;
	    }
	};

	torrent_check($tdata, $tdata->{'rtorrent'}{'directory'}) or next;

        if ( defined $tdata->{'rtorrent'}{'complete'} && $tdata->{'rtorrent'}{'complete'} == 1 ) {
	    print "This torrent is finished\n" if $opt{'verbose'}; next;
	}


	#try resume this torrent
	unless ( resume($tdata, 1) ) {
	    print "Something went wrong when resuming $tdata->{'info'}{'name'}\nTry verbose mode to see more info. Moving to next file\n";
	    next;
	}

	#save session file
	&savertsession($torrent);
    }

}

#returns bdecoded data or undef if file is broken or not readable
# params:
# 0 - path to the file
# 1 - ref to a variable where to put bdecoded data
# 2 - do coerce on bdecode
sub load_file {
    my ($file, $data, $coer) = @_;

	$Convert::Bencode_XS::COERCE = $coer;

    unless (open(FP, $file)) { print "Could not open file $file: $!"; return undef; }
    print "Loading file - $file with coerce=$coer\n" if $opt{'verbose'};

    local $/=undef;
    binmode(FP);
    {
		${$data} = bdecode(<FP>);
		# or die "Can't decode bencoded data\n";
    }
    close(FP);

	print "Loaded torrent structure:\n" if $debug;
    print Dumper(${$data}) if $debug;

	return 1;
}

#return true if scalar is integer digits only
sub onlydigits {
	my $str = shift;

	return 1 if ($str =~ m/^\d+$/);

	return 0;
}

#return true if scalar is over 2^31-1
sub over2gb {
	my $str = shift;
	return 1 if ($str > 2147483648 );
	return 0;
}

# check torrent content if it must be coerced or not on bencode/bdecode
# by default coerce is enabled and true is returned if no issues
# if there are path elements decoded as int's that torrent file is reloaded without coerce
# and false is returned
# if nither options are sutable than undef is returned
sub coercechck {
	my ( $dref, $file ) = @_;
	my $strasint = 0;
	my $largefile = 0;
	my $data = ${$dref};

    if ( is_multi($data) ) {
		for (@{$data->{'info'}{'files'}}) {
			for ( @{$_->{'path'}} ) {
				if ( onlydigits($_) ) {
					$strasint = 1;
					last if $strasint;
				}
			}
			if (over2gb($_->{'length'})) { $largefile =1;}
			last if ( $largefile && $strasint);
		}
    } else {
		$strasint = onlydigits($data->{'info'}{'name'});
		$largefile = $data->{'info'}{'length'};
    }


	if ($strasint && $largefile) {
		print "Torrent has filepath with digits-only element AND some file has size over 2Gb\n!!!Resuming such torrents is possible in session mode only due to perl scalar handling :(((\n";
		return undef;
	} elsif ($strasint) {
		print "Torrent has filepath with digits-only, bdecoding without coerce\n" if $opt{'verbose'};
		#switch global coerce to 0, cause we need to bencode without corce too
		load_file($file, $dref, 0);
		return 0;
    }

	return 1;
}

# do base check fot torrent file
# return INFOHASH on success or undef otherwise
sub torrent_check {
    my ($data, $chkpath) = @_;

    unless (ref $data eq "HASH" and exists $data->{'info'}) { print "No info key.\n"; return undef; }

    print "Torrent name: $data->{'info'}{'name'}\n" if (defined $data->{'info'}{'name'} && $opt{'verbose'});

    unless ( $chkpath = chk_basedir($chkpath, $data) ) {
	  print "Torrent base path is wrong, aborting...\n";
	  return undef;
    }

    #Set rtorrent directory, we'll need it later
    $data->{'rtorrent'}{'directory'} = $chkpath unless $opt{'session'};
	return uc(sha1_hex(bencode($data->{'info'})));
}


# sub getfiles checks torrent data for errors, makes basic calculations and
# returns ref to a list of all files in torrent
sub getfiles {
    my $t = shift;

    unless ( $chunk_size = $t->{'info'}{'piece length'} ) {print "No piece length key.\n"; return undef; }

    my @files = ();
    $tsize = 0;
    if ( is_multi($t) ) {
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

    $chunks = chunks($tsize,$chunk_size);
    if ($opt{'verbose'}) {print "Total: $tsize bytes; $chunks chunks; ", @files . " files\n";}
    if ($opt{'verbose'}) {print "Chunks hash length: " . length $t->{'info'}{'pieces'}; print " bytes\n\n";}

    unless ( $chunks * CHUNK_HASH_SIZE == length $t->{'info'}{'pieces'} ) { print "Inconsistent chunks hash information!\n"; return undef;}

    return \@files;
}

# resume torrent
# Options:
# $tdata - reference to a torrent data
sub resume{

    my ($tdata) = @_;

    my $files;
    unless ( $files = getfiles($tdata) ) { print "WARNING: Can't get file list from torrent\n"; return undef; };

    my $d = $tdata->{'rtorrent'}{'directory'} . '/';

    my $ondisksize = 0;		#on-disk data size counter
    my $boffset = 0;		#block offset
	my $missing = 0;		#chunks missing

    for (0..$#{$files}) {
		my @fstat = -f "$d${$files}[$_]" ? stat "$d${$files}[$_]" : () ;

		#just a precaution, check if file's size match on-disk size
		my $trnt_length = is_multi($tdata) ? $tdata->{'info'}{'files'}[$_]{'length'} : $tdata->{'info'}{'length'};

		unless ( defined $fstat[7] ) {
			unless (defined $opt{'unfinished'} && $opt{'unfinished'}) { print "File: $d${$files}[$_] doesn't exist. Use '--unfinished' to do partial resume\n"; return 0; };
			print "Not found $d${$files}[$_]\n" if $opt{'verbose'};
			$fstat[7] = 0;
		} elsif ( $trnt_length != $fstat[7] ){
			print "File: $d${$files}[$_] \non-disk file-size $fstat[7] doesn't match in-torrent size $trnt_length\n" if ($opt{'verbose'} || not $opt{'force'});
			unless ($opt{'force'}) { print "Aborting resume... Use '--force' to override and reset file to unfinished state\n"; return 0; };
			print "reseting resume info\n";
			$fstat[7] = 0;
		}

		#process non-existent/empty files
		unless ( $fstat[7] ) {
			# fixme: partial session support
			# not $tdata->{'libtorrent_resume'}{'files'}["$_"]{'priority'} ) {

			#mark chunks for this file as missing in chunks bitvector
			$missing = recalc_bitfield( $boffset, $trnt_length ) if $trnt_length;

	        my($filename, $dirpath, $suffix) = fileparse("$d${$files}[$_]");

		    #create nonexistent files
	  		unless ( -f "$d${$files}[$_]" ) {
				print "Creating zero byte file: $d${$files}[$_]\n\n" if $opt{'verbose'};

				# recreate dir path if missing
				unless ( -d $dirpath ) {
					make_path($dirpath) or return undef
				}

				open(FILE,">>$d${$files}[$_]") or return undef; #die "Can't create file $d${$files}[$_]";
				close(FILE);

				#refresh fstat for the new file
				@fstat = stat "$d${$files}[$_]" or return undef;
			}
		}

		$tdata->{'libtorrent_resume'}{'files'}[$_] = {
			'mtime' => $fstat[9] ? $fstat[9] : time,
			'completed' => $fstat[7] ? filechunks($boffset, $fstat[7]) : 0,
		};

		#Do not download non-exitent files
		#unless ($fstat[7] && $make_empty) { $tdata->{'libtorrent_resume'}{'files'}[$_]{'priority'} = 0;  }

		# count real on-disk data size
		$ondisksize += $fstat[7];
		# shift file pointer
  		$boffset += $trnt_length;
    };

    # resume failed if ondisk size = 0 (no files to resume actualy) or
    # ondisk size doens't match sum off all files in torrent and we were not requested to resume missing files
    if ( defined $opt{'unfinished'} && $opt{'unfinished'} != 1 && $ondisksize != $tsize ||  $ondisksize == 0 ) {
		print "Oops! Files size verification failed\n";
		print "Either not all files present or nothing to resume at all\n";
		print "In torrent size = $tsize,\t on-disk size = $ondisksize\n";
		return undef;
    }

    print "\nResume summary for torrent $tdata->{'info'}{'name'}:\n$missing out of $chunks chunks missing\n";

	my $rt_data = {
		'chunks_wanted' => $missing,
  		'chunks_done' => $chunks - $missing,
  		'complete' => $missing ? 0 : 1,
		'timestamp.finished' => $missing ? 0 : time,
		'timestamp.started' => time,
		#'state' = 1;	#autostart torrent
	};

    #set resume vars in torrent
	$tdata->{'rtorrent'} = { %{$tdata->{'rtorrent'}}, %$rt_data };
    $tdata->{'libtorrent_resume'}{'bitfield'} = $chunks unless ($missing);

    return 1;
}


#loads additional data for the new rtorrent versions to the global array
#returns 1 if success, 0 otherwise
sub load_rtdata {
    my ($file, $t) = @_;
    load_file($file . '.libtorrent_resume', \$t->{'libtorrent_resume'}, 1) or return 0;
    load_file($file . '.rtorrent', \$t->{'rtorrent'}, 1) or return 0;
    return 1;
}

# saves bencoded data to the session
sub savertsession {
    my $file = shift;

    if ( $opt{'old-version'} ) {
	savetofile($tdata, $file, $coerce) or return undef;
    }
    else {
	#save libtorrent_resume
	savetofile($tdata->{'libtorrent_resume'}, $file . '.libtorrent_resume', 1) or return undef;
	savetofile($tdata->{'rtorrent'}, $file . '.rtorrent', 1) or return undef;
    }
    return 1;
}

# saves bencoded data to file
# args - reference to a data to bencode
#      - file name with full path
sub savetofile {
    my ($data, $file, $coer) = @_;

	$Convert::Bencode_XS::COERCE = $coer;

	# do cleance on rtorrent data integers if global coerce = 0
	rtclean($data) unless $coer;

    unless ( open(FP, ">$file") ) { print "Could not open file $file for writing:\n $!"; return undef; }
    print "Saving bencode to file $file with coerce $coer\n" if $opt{'verbose'};

    my $content = bencode($data);

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
    my ($offset, $size) = @_;

    my $bf; 	#bitfield vector
    my $x;		#mode of operation 0 - for new torrents, 1 - for session
    my $fill;	# not x actualy

    $x = $opt{'session'} ? 0 : 1; $fill = $x ? 0 : 1;

    #init vector
    if ( not defined $tdata->{'libtorrent_resume'}{'bitfield'} ) {
		$bf = $x x $chunks;
    } else {
		$bf = unpack("B$chunks", $tdata->{'libtorrent_resume'}{'bitfield'});
    }

    my $missingchunks = filechunks($offset, $size);

    print "Chunk offset: " . chunks($offset, $chunk_size) . "; missing $missingchunks chunks\n\n" if $debug;
    substr $bf, chunks($offset, $chunk_size), $missingchunks, $fill x $missingchunks;
	my $missing = $bf =~ tr/0//;

	print "Chunks missing: $missing\n" if ($debug);
    print "BF length - " . length($bf) . "\n" if ($debug > 1);
    print "Chunk map:\n" . join(':', unpack("(A8)*", $bf)) . "\n===\n" if ($debug > 1);

    $tdata->{'libtorrent_resume'}{'bitfield'} = pack("B$chunks", $bf);

    return $missing;
}

# return number of block with size $bsize required
# to fit specified amount of bytes
sub chunks {
    my ($length, $bsize) =@_;
    my $div = int($length / $bsize);
    $length % $bsize ? return ($div+1) : return $div ;
}


# find how many chunks it needs to fit block of data
# with size S begining at specified offset F
sub filechunks {
    my ($offset, $size) =@_;

	#one extra byte to offset is required to cross chunk boundary
	#one extra chunk is the one where file begins
	return ( chunks($offset + $size, $chunk_size) - chunks($offset + 1, $chunk_size ) + 1 );
}

#checks the base path so we can find out if there is anything to resume
#returns path suitable to put in rtorrent->directory option or undef if any error
sub chk_basedir {
    my ($path, $trnt) = @_;

    unless ( &chkdir(\$path) ) { print "Base $path is not a dir\n" if $opt{'verbose'}; return undef; }

    if ( is_multi($trnt) ) {
		#in session torrents this path is already set
		$path = $path . $trnt->{'info'}{'name'} unless $opt{'session'};

		my $dh;
        #base dir for multifile  torrent must be at least not empty or we got nothing to do here
		unless ( opendir($dh, $path) ) { print "Can't open dir $path, $!\n"; return undef; }
		unless ( scalar(grep( !/^\.\.?$/, readdir($dh))) ) { print "Directory $path is empty\n";  return undef; }
    } else {
	unless ( -e $path . $trnt->{'info'}{'name'} ) {
	    print "No file under the base path so nothing to resume here\n" if $opt{'verbose'};
	    return undef;
	}
	#chop / from &chkdir function
	chop $path;
    }

    return $path;
}

# return true if torrent is multifile
sub is_multi {
	my ($td) = @_;
    return exists $td->{'info'}{'files'};
};

sub rtclean {
    my ($d) = @_;

    print "Cleansing rtorrent data\n" if $debug;

    intcleanse(\$d->{'rtorrent'}{'chunks_wanted'});
    intcleanse(\$d->{'rtorrent'}{'chunks_done'});
    intcleanse(\$d->{'libtorrent_resume'}{'bitfield'}) unless $d->{'rtorrent'}{'chunks_wanted'};

    if ( is_multi($d) ) {
        for (@{$d->{'info'}{'files'}}) {
            intcleanse( \$_->{'length'} );
        }
    } else {
                intcleanse(\$d->{'info'}{'length'});
    }
}

# cleanse integer
sub intcleanse {

    my $ref = shift;

	return unless defined $$ref;
    #can't cleanse ints more than 2^31-1
    print "Clensing int: $$ref\n" if ($debug > 1);
    if ($$ref < 2147483648 || $opt{'force'}) {
        cleanse($$ref);
    } else {
        die("Cleansing integers over 2Gb is not supported yet\nUse '--force' to override if U know what you are doing\n");
    }
}

# dump torrent file structure
sub tdump {
  my ($opt, $file) = @_;
  my $tdata;
  $debug=1;
  load_file($file, $tdata, $coerce);
  exit 0;
}

# urlenc (solution from webmin libraries)
sub urlize {
  my ($rv) = @_;
  $rv =~ s/([^A-Za-z0-9])/sprintf("%%%2.2X", ord($1))/ge;
  return $rv;
}


# transmission to rtorrent session converter
sub t2r {
    my ($src, $dst) = @_;
	my $cnt = 0;

    chdir $src or die "Cannot chdir to session directory $src: $!\n";

    my @torrents = glob("torrents/*.torrent");

    foreach ( @torrents ) {

	  my $torrent = $_;
	  $torrent =~ m#torrents/(.+)\.torrent$#;
	  my $tr_basename = $1;
	  my $tr_resume_file = $tr_basename . '.resume';
	  my $tr_res;	#transmission resume data

	  print "\n====\nProcessing file $torrent\n";
	  print "Transmission resume file $tr_resume_file\n" if $opt{'verbose'};

	  unless(load_file($torrent, \$tdata, $coerce))  { print "WARNING: Can't load $_\n"; next; };
	  unless(load_file("resume/$tr_resume_file", \$tr_res, $coerce)) { print "WARNING: Can't load $_\n"; next; };

	  unless ( defined $tr_res->{'progress'}{'have'} && $tr_res->{'progress'}{'have'} =~ m/all/ ) {
		print "Unfinished torrents is not supported, skip...\n";
		next;
	  }

	  # add base dir path
	  my $infohash = torrent_check($tdata, $tr_res->{'destination'}) or next;

	  unless (resume($tdata, 0)) {
		print "Resume failed, skip...\n";
		next;
	  }

	  my $rt_data = {
		'state' => $tr_res->{'paused'} ? 0 : 1,
		#'complete' => defined $tr_res->{'progress'}{'have'} ? 1 :0,
		'custom' => {'addtime' => $tr_res->{'added-date'} },
		'timestamp.finished' => $tr_res->{'done-date'},
		'state_changed' => $tr_res->{'activity-date'},
		'total_uploaded' => $tr_res->{'uploaded'},
		'total_downloaded' => $tr_res->{'downloaded'},
		'custom1' => 'transmission',
		'hashing' => 0,
  	  };

	  $tdata->{'rtorrent'} = { %{$tdata->{'rtorrent'}}, %$rt_data };
	  $tdata->{'rtorrent'}{'custom'}{'x-filename'} = urlize($tr_basename . '.torrent');
	  $tdata->{'rtorrent'}{'tied_to_file'} = $src . $torrent if $opt{'tied'};

	  my $dst_file = $dst . $infohash . '.torrent';
	  unless (copy("$torrent", "$dst_file" )) { print "File copy failed, skip\n"; next; }
	  print "Saving session for torrent infohash: $infohash\n";
	  $tdata->{'rtorrent'}{'loaded_file'} = $dst_file;

	  #save session file
	  &savertsession($dst_file);
	  ++$cnt;

  	  if ( $opt{'remove-source'} ) {
		unlink $torrent or print "Can't remove file $torrent: $!\n";
		unlink "resume/$tr_resume_file" or print "Can't remove file resume/$tr_resume_file: $!\n";
  	  }
    }

	print "\n===\n===\n$cnt out of " . scalar @torrents . " torrents converted\n";

}

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

=head1 USAGE

    rfr.pl [options] file ...
    rfr.pl [options] -s|--session <path>
	rfr.pl [-vdt] --t2r <transmission_session> -d <rtorrent_session>
	rfr.pl --dump <torrent_file>

    Options:
    -b, --base	<path>		Base directory to look for data files
    -D, --debug			debug output. WARNING! This will produle a lot of output including bencoded data dump,
				it's stongly advised to redirect STDOUT to a file, so it will not trash you terminal.
				Specify twice to produce even more debug output, including bitfield vector for each file.
    -d, --destination <path>	destination dir|file to save resumed torrent file
    --dump				Bdecode and print torrent structure
    -f, --force			Force actions that could lead to corrupted torrents
    -h, --help	  		brief help message
    --man        		full documentation
    -o, --old-version		use old rtorernt session format with all data in one file (for rtorrent <8.9)
    -r, --remove-source		remove source torrent file if resume was successful
    -s, --session <path>	resume all torrents in rtorrent session directory under <path>
    -t, --tied				Tie session file to source torrent
    -u, --unfinished		check for missing files and resume partialy downloaded torrent
    -v, --verbose		be more verbose about what's going on there

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

=head1 Convert Transmission session into RTorrent session

If You decided to quit using Transmission and switch to RTorrent but do not want to manually reload and rehash all
of your torrents one by one. Sure you want to keep as much data as possible, like creation time, UL/DL values,
autoset destination dir etc? There is a way to convert Transmission session into RTorrent session. Use rfr.pl to
do this - just provide path to transmission session dir as a source and RTorrent session dir as a destination,
than reload rtorrent. Only full-finished torrent with valid destination path would be converted, partial seeding
and incomplete downloads are not supported.


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

* Load any torrent and dump it's structure to stdout without any checks

	./rfr.pl --dump some.torrent

* Convert Transmission session files into RTorrent session
	./rfr.pl --t2r ~/transmission/ -d ~/rt/session/


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

