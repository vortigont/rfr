## Rtorrent fast resumer

Perl script to add fast resume data to torrent files used by rtorrent.


### DESCRIPTION

This script is intended to add fast resume data to rtorrent, so you don't need to hash-recheck all data if for some reason you are sure that
your data is exactly the same as referenced in torrent file.
Initialy it was based on rtorrent_fast_resume.pl by Josef Drexler http://libtorrent.rakshasa.no/downloads/rtorrent_fast_resume.pl
but later was completely rewriten to add more nice features and options.

This version supports:

 - extended command line options processing and features
 - processing multiple torrents from one command
 - resuming torrents with missing files (yep, it's nice!)
 - automated rtorrent session files resuming

### OPTIONS

    rfr.pl [options] [file ...]

    Options:
    -b, --base	<path>		Base directory to look for data files
    -D, --debug			debug output. WARNING! This will produle a lot of output including bencoded data dump,
				it's stongly advised to redirect STDOUT to a file, so it will not trash you terminal
    -d, --destination <path>	destination dir|file to save resumed torrent file
    -h, --help	  		brief help message
    --man        		full documentation
    -o, --old-version		use old rtorernt session format with all data in one file (for rtorrent <8.9)
    -r, --remove-source		remove source torrent file if resume was successful
    -s, --session <path>	resume all torrents in rtorrent session directory under <path>
    -u, --unfinished		check for missing files and resume partialy downloaded torrent
    -v, --verbose		be more verbose about what's going on there

    [file]			torrent file to resume

    See --man help page and examples section for more info.

### Command Line Options, an Usage

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

#### Resume partialy downloaded torrents

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

#### Session directory resuming

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


### EXAMPLES

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


#### AUTHOR

Emil Muratov <gpm@hotplug.ru> (c) 2012

Based on code rtorrent_fast_resume.pl by Josef Drexler
http://libtorrent.rakshasa.no/downloads/rtorrent_fast_resume.pl

#### COPYRIGHT AND DISCLAIMER

Copyright (c) 2012 Emil Muratov

This program is free software; you can redistribute it and/or
modify it under the terms of "Simplified BSD License" or "FreeBSD License"

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; See the Simplified BSD License for more details.


