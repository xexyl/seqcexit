#!/usr/bin/perl -w
#
# seqcexit - sequence C exit codes for exit(), usage(), err(), errp()
#
# Copyright (c) 2021 by Landon Curt Noll.  All Rights Reserved.
#
# Permission to use, copy, modify, and distribute this software and
# its documentation for any purpose and without fee is hereby granted,
# provided that the above copyright, this permission notice and text
# this comment, and the disclaimer below appear in all of the following:
#
#       supporting documentation
#       source copies
#       source works derived from this source
#       binaries derived from this source or from derived source
#
# LANDON CURT NOLL DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE,
# INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO
# EVENT SHALL LANDON CURT NOLL BE LIABLE FOR ANY SPECIAL, INDIRECT OR
# CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF
# USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
# OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
# PERFORMANCE OF THIS SOFTWARE.
#
# chongo (Landon Curt Noll, http://www.isthe.com/chongo/index.html) /\oo/\
#
# Share and enjoy! :-)

# requirements
#
use strict;
use bytes;
use vars qw($opt_v);
use Getopt::Long;
use File::Basename;
use File::Temp qw(tempfile);

# version
#
my $VERSION = "1.0 2021-12-29";

# my vars
#
my $file;	# required argument

# usage and help
#
my $usage = "$0 [-v lvl] [-l low] [-h high] [-n] [-s] file.c [file2.c ...]";
my $help = qq{$usage

	-v lvl		verbose / debugging level (def: 0)
	-l low		low exit code range (must be >=0 and < high) (def: 0)
	-h high		high exit code range (must be >low and < 256) (def: 249)
	-n		do not change, nor create files
	-s		keep a copy of the original filenmame as filename.orig.c

	file.c ...	C source file to process
};
my $low = 0;		# low exit code range
my $high = 249;		# high exit code range
my $noop = undef;	# change nor create no files
my $save_orig = undef;	# keep the original file as foo.orig.c
my %optctl = (
    "v=i" => \$opt_v,
    "l=i" => \$low,
    "h=i" => \$high,
    "n" => \$noop,
    "s" => \$save_orig,
);


# function prototypes
#
sub nextexitcode($);
sub error($@);
sub dbg($@);


# setup
#
MAIN: {
    my $ARGV;	# file argument on the command line
    my $line;	# line from open file
    my $tmp_fh;			# temporary file handle
    my $tmp_filename;		# temporary file name
    my $exit_seq = undef;	# exit sequence number

    # setup
    #
    select(STDOUT);
    $| = 1;

    # set the defaults
    #
    $opt_v = 0;

    # parse args
    #
    if (!GetOptions(%optctl)) {
	error(1, "invalid command line\nusage: $help");
    }
    if ($#ARGV < 0) {
	error(2, "missing required argument\nusage: $help");
    }
    if ($low < 0) {
	error(3, "low must be >= 0\nusage: $help");
    }
    if ($high > 255) {
	error(4, "high must be < 256\nusage: $help");
    }
    if ($low >= $high) {
	error(5, "low must be < high\nusage: $help");
    }

    # cycle thru lines of the argument
    #
    while ($ARGV = shift @ARGV) {

	# process only *.c files
	dbg(1, "# considering $ARGV");
	if ($ARGV =~ /\.c$/) {

	    # open file if possible
	    #
	    open(FH, $ARGV) or do {
		dbg(1, "# skipping file, cannot open $ARGV: $!");
		next;
	    };
	    dbg(2, "# open $ARGV");

	    # open a mnew tempotary file
	    #
	    if (! defined($noop)) {
		($tmp_fh, $tmp_filename) = tempfile("c.tmpfile.XXXXX",
						     DIR => dirname($ARGV),
						     SUFFIX => '.c',
						     EXLOCK => 1);
		dbg(1, "# forming $tmp_filename");
	    }

	    # process each line in the file
	    #
	    while ($line = <FH>) {

		# do not exit code process lines with /*ooo*/
		#
		if ($line !~ /\/\*ooo\*\//) {
		    my ($pre, $funcname, $whiteparen, $code, $post);	# parse function line
		    my ($prev_exit_seq, $orig_code);

		    # look for line of the form (were 99 is any set of exit code digits)
		    #
		    #	exit(99);
		    #	err(99, ...
		    #	errp(99, ...
		    #	usage(99, ...
		    #
		    # We will ignore lines with whitespace around the exit code.
		    #
		    #	$1	beginning of line up to the calling function
		    #	$2	calling function (exit|err|errp|usage)
		    #	$3	white and ( before the exit code
		    #	$4	exit codde
		    #	$5	text after exit code
		    #
		    if ($line =~ /^(.*\b)(err|errp|usage)(\s*\()(\d+)(,.*)$/ ||
		    	$line =~ /^(.*\b)(exit)(\s*\()(\d+)(\);.*)$/) {

			# save matched expressions
			#
			$pre = $1;
			$funcname = $2;
			$whiteparen = $3;
			$code = $4;
			$post = $5;
			dbg(5, "possible exit sequenceing call: $funcname$whiteparen$code");
			dbg(6, "possible exit sequenceing line: $pre$funcname$whiteparen$code$post");

			# if first exit number, start with this sequence
			#
			$orig_code = $code;
			$prev_exit_seq = $exit_seq;
			if (! defined($exit_seq)) {
			    $exit_seq = $code;

			# otherwise use the next in the sequence
			#
			} else {
			    $exit_seq = nextexitcode($exit_seq);
			    $code = $exit_seq;
			}

			# skip sequencing if $pre is an open C /* comment
			#			  or in a multi-line * comment
			#			  or in a // comment
			#
			# While not perfect, the regular expression will catch the case
			# where we are in the middle of a comment.
			#
			if ($pre =~ /\/\*[^*\/]*$/ || $pre =~ /\s*\*\s*$/ || $pre =~ /\/\//) {

			    # /* do not alter exit code, nor change exit the sequence */
			    dbg(5, "restoring line, likely open comment found: $pre");
			    $exit_seq = $prev_exit_seq;
			    $code = $orig_code;

			# if we find a /*coo*/ comment, then reset the sequence
			#
			} elsif ($pre =~ /\/\*coo\*\// || $post =~ /\/\*coo\*\//) {

			    # force the exit sequence to change to match current line
			    #
			    dbg(4, "found /*coo*/, reset exit sequence from $exit_seq to $orig_code");
			    $exit_seq = $orig_code;
			    $code = $orig_code;
			}
			if ($code != $orig_code) {
			    dbg(3, "change exit code on line from $orig_code to $code");
			}

			# reform line with sequenced exit code
			#
			$line = $pre . $funcname . $whiteparen . $code . $post . "\n";
		    }
		}

		# print the (possibly modified) line to the temp file
		#
		if (! defined($noop)) {
		    print $tmp_fh $line or die "connot write line to $tmp_filename: $!";
		}
	    }

	    # close the temporary file
	    #
	    if (! defined($noop)) {
		dbg(2, "# close $tmp_filename");
		close $tmp_fh or die "cannot close $tmp_filename: $!";
	    }

	    # close the file
	    #
	    dbg(2, "# close $ARGV");
	    close FH or die "cannot close $ARGV: $!";

	    # case: -s
	    #
	    # Move original file.c to file.orig.c
	    #
	    if (defined($save_orig)) {
		my $orig_file = $ARGV;
		$orig_file =~ s/\.c$/.orig.c/;
		if (! defined($noop)) {
		    dbg(1, "mv -v $ARGV $orig_file");
		    rename($ARGV, $orig_file) or die "cannot rename $ARGV to $orig_file: $!";
		}
	    }

	    # code: no -s and no -n
	    #
	    # move temp filename into place, unlewss
	    #
	    if (! defined($noop)) {
		dbg(1, "mv -v $tmp_filename $ARGV");
		rename($tmp_filename, $ARGV) or die "cannot rename $tmp_filename to $ARGV: $!";
	    }

	} else {
	    dbg(1, "# skipping non *.c filename: $ARGV");
	}
    }
    exit(0);
}


# nextexitcode - return the next non-zero valid exit code
#
# We select the next exit code beyond $exitcode, which is usually $exitcode+1,
# except when $exitcode >= $high in which case $low is considered.  However
# if $low == 0, then 1 is used instead.
#
# given:
#	$exitcode	current exit code
#
# returns:
#	next exit code that is within non-zero exit code range
#
sub nextexitcode($)
{
    my $current_code = shift @_;	# get exit code
    my $ret;				# exit code to consider

    # consider next exit code
    #
    $ret = $current_code + 1;

    # wrap to low if beyond high
    #
    if ($ret > $high) {
	$ret = $low;
    }

    # do not reuse (due to wrapping) 0, jump to 1 instead
    #
    if ($ret <= 0) {
	$ret = 1;
    }
    return $ret;
}


# error - report an error and exit
#
# given:
#       $exitval	exit code value
#       $msg ...	error message to print
#
sub error($@)
{
    my ($exitval) = shift @_;	# get args
    my $msg;			# error message to print

    # parse args
    #
    if (!defined $exitval) {
	$exitval = 254;
    }
    if ($#_ < 0) {
	$msg = "<<< no message supplied >>>";
    } else {
	$msg = join(' ', @_);
    }
    if ($exitval =~ /\D/) {
	$msg .= "<<< non-numeric exit code: $exitval >>>";
	$exitval = 253;
    }

    # issue the error message
    #
    print STDERR "$0: $msg\n";

    # issue an error message
    #
    exit($exitval);
}


# dbg - print a debug message is debug level is high enough
#
# given:
#       $min_lvl	minimum debug level required to print
#       $msg ...	debug message to print
#
# NOTE: The DEBUG[$min_lvl]: header is printed for $min_lvl >= 0 only.
#
# NOTE: When $min_lvl <= 0, the message is always printed
#
sub dbg($@)
{
    my ($min_lvl) = shift @_;	# get args
    my $msg;			# debug message to print

    # firewall
    #
    if (!defined $min_lvl) {
    	error(97, "debug called without a minimum debug level");
    }
    if ($min_lvl !~ /-?\d/) {
    	error(98, "debug called with non-numeric debug level: $min_lvl");
    }
    if ($opt_v < $min_lvl) {
	return;
    }
    if ($#_ < 0) {
	$msg = "<<< no message supplied >>>";
    } else {
	$msg = join(' ', @_);
    }

    # issue the debug message
    #
    if ($min_lvl < 0) {
	print STDERR "$msg\n";
    } else {
	print STDERR "DEBUG[$min_lvl]: $msg\n";
    }
}