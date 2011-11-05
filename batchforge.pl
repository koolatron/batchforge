#!/usr/bin/perl -w

# batchforge.pl -- a batch wrapper for skeinforge
#
#  Description
#  ===========
#  The purpose of this script is to give skeinforge a non-interactive mode
#  capable of operating on multiple files and multiple profiles, while still
#  approximating the configurability of skeinforge's GUI.  This script is
#  intended to live in the skeinforge_application directory of your skeinforge
#  installation, but doesn't necessarily need to.
#
#  This script will take a list (or directory) of input models in any format
#  that skeinforge can ordinarily deal with (most commonly .stl), a list of
#  profiles to use for conversion, and an output directory.
#
#  Examples
#  ========
#  Convert test.stl using the "PLA" profile, output to ~/gcodes:
#   perl batchforge.pl -input test.stl -profile PLA -output ~/gcodes
#
#  Convert all files in ~/stlfiles using "PLA" and "ABS" profiles:
#   perl batchforge.pl -input ~/stlfiles -profile PLA -profile ABS -output ~/gcodes

use Getopt::Long;
use Scalar::Util qw(reftype);
use Cwd;
use FindBin qw($Bin);
use strict;

$SIG{INT} = \&SIGINT;

my %opts;
if (!&GetOptions(
        \%opts,    'profile=s@', 'input=s@',   'output=s',
        'sfdir=s', 'verbose',    'maxTasks=s', 'patch=s@',
        'help',
    )
    || ( !$opts{input} )
    || ( $opts{help} )
    )
{
    print <<USAGE; exit 1;
usage: $0 -input [input file(s)] -output [output directory] options

Required arguments:
	input		The list of files to convert.  This can be any of the
			formats Skeinforge is capable of handling and can be
			specified multiple times.  Will operate on directories.

	output		Base directory for output of gcode files.
			

Optional arguments:
	profile		The extrusion profile to use.  If unspecified, uses the
			default profile, which is the one that was selected the
			last time you ran the Skeinforge GUI.  This can be
			specified multiple times.

	sfdir		The path to your Skeinforge application directory.  If
			unspecified, it'll default to the the current working
			directory.

	patch		Apply a one-time patch to a profile.  Arguments take the
			form "profile:module:parameter:value".  This is useful
			for adjusting variables like multiply settings where you
			wouldn't typically want to save your changes.

			  examples:
			    -patch "PLA:multiply:Number of Columns (integer):2"
			    -patch "ABS:raft:Activate Raft:False"

	maxTasks	By default, we fork if there are tasks with enough
			shared variables.  Defaults to two.

	verbose		Be more verbose with output.

	help		This helpful message.
USAGE
}

# Set up verbosity
if ( $opts{verbose} ) {
    open VERBOSE, ">&", \*STDOUT;
}
else {
    open VERBOSE, ">", "/dev/null";
}

# Set up some useful variables
my $profileFile
    = -d "/Users"
    ? "/Users/" . getlogin() . "/.skeinforge/profiles/extrusion.csv"
    : "/home/" . getlogin() . "/.skeinforge/profiles/extrusion.csv";
my $sfdir = $opts{sfdir} ? $opts{sfdir} : $Bin;
$opts{maxTasks} = $opts{maxTasks} ? $opts{maxTasks} : 2;
my @profiles = @{ $opts{profile} }
    if ( reftype $opts{profile} && reftype $opts{profile} eq 'ARRAY' );
my @inputs = @{ $opts{input} }
    if ( reftype $opts{input} && reftype $opts{input} eq 'ARRAY' );
my @patches = @{ $opts{patch} }
    if ( reftype $opts{patch} && reftype $opts{patch} eq 'ARRAY' );

# Input checking
print VERBOSE "Skeinforge utilities directory...\n";
if ( -d "$sfdir/skeinforge_utilities" ) {
    print VERBOSE "  $sfdir/skeinforge_utilities\n";
}
else {
    print VERBOSE "  $sfdir/skeinforge_utilities NOT FOUND\n";
    exit 1;
}

print VERBOSE "Checking extrusion profile csv...\n";
if ( -e "$profileFile" ) {
    print VERBOSE "  $profileFile\n";
}
else {
    print VERBOSE "  $profileFile NOT FOUND\n";
    exit 1;
}

print STDOUT "Checking extrusion profiles...\n";
for my $profile (@profiles) {
    if ( -d "$sfdir/profiles/extrusion/$profile" ) {
        print STDOUT "  $sfdir/profiles/extrusion/$profile\n";
    }
    else {
        print STDOUT "  $sfdir/profiles/extrusion/$profile NOT FOUND\n";
        exit 1;
    }
}
if ( !@profiles ) {
    print STDOUT "  Using default profile\n";
    push @profiles, "DefaultProfile";
}

print STDOUT "Checking input files...\n";
for my $inputFile (@inputs) {
    if ( -d "$inputFile" ) {
        @inputs = `find $inputFile | egrep -v "$inputFile\$"`;
    }
    chomp @inputs;
}

for my $inputFile (@inputs) {
    if ( -e "$inputFile" ) {
        print STDOUT "  $inputFile\n";
    }
    else {
        print STDOUT "  $inputFile NOT FOUND\n";
        exit 1;
    }
}

print STDOUT "Checking base output path...\n";
if ( -d "$opts{output}" ) {
    print STDOUT "  $opts{output}\n";
}
else {
    print STDOUT "  $opts{output} NOT FOUND\n";
    exit 1;
}

# Back up the extrusion.csv file in case we mess it up
print VERBOSE "Backing up $profileFile...\n";
`cp $profileFile $profileFile.bak`;

# Iterate and convert
for my $profile (@profiles) {
    if ( $profile ne "DefaultProfile" ) {

        # Set profile.  HACK.
        print VERBOSE "Setting profile to $profile in $profileFile...\n";
        open PROFILE,    "<", "$profileFile";
        open PROFILENEW, ">", "$profileFile.new";
        while (<PROFILE>) {
            my $line = $_;
            if ( $line =~ /Profile Selection/ ) {
                $line = "Profile Selection:	$profile\n";
            }
            print PROFILENEW $line;
        }
        close PROFILE;
        close PROFILENEW;
        `mv $profileFile.new $profileFile`;
    }
    else {
        open PROFILE, "<", "$profileFile";
        while (<PROFILE>) {
            my $line = $_;
            if ( $line =~ /Profile Selection:\t(.*)/ ) {
                $profile = $1;
            }
        }
        close PROFILE;
        print VERBOSE "Using default profile $profile...\n";
    }

    # Patch parameters if necessary
    for my $patch (@patches) {
        my ( $pProfile, $pModule, $pParam, $pValue ) = split /:/, $patch;
        next
            unless ( $pProfile eq $profile
            && $pModule
            && $pParam
            && $pValue );
        print VERBOSE
            "Patching requested for $profile:$pModule:$pParam:$pValue\n";

        # Validate patch before trying to apply anything
        print STDOUT "Validating patch...\n";

        # Verify presence of module config before attempting to patch it
        my $dotsfdir
            = -d '/Users'
            ? "/Users/" . getlogin() . "/.skeinforge"
            : "/home/" . getlogin() . "/.skeinforge";

        my $moduleFile
            = -e "$dotsfdir/profile/extrusion/$pModule.csv"
            ? "$dotsfdir/profiles/extrusion/$profile/$pModule.csv"
            : "$sfdir/profiles/extrusion/$profile/$pModule.csv";

        unless ( -e $moduleFile ) {
            print STDOUT
                "  $pModule not found in any Skeinforge-related directory.\n";
            next;
        }

        # Verify that module config contains the parameter we want to patch
        my $foundParam;
        open MODULE, "<", $moduleFile;
        while (<MODULE>) {
            my $line    = $_;
            my $qmParam = quotemeta($pParam);
            if ( $line =~ /^$qmParam:?\t/ ) {
                print VERBOSE "  $line";
                $foundParam = "YES";
                last;
            }
        }
        close MODULE;

        unless ($foundParam) {
            print STDOUT
                "  $pModule exists but the specified parameter, $pParam, was not found.\n";
            next;
        }

        # Back up the patched file so we can restore it later.
        unless ( -e "$moduleFile.bak" ) {
            print VERBOSE "Backing up $moduleFile...\n";
            `cp $moduleFile $moduleFile.bak`;
        }

        # Do the patch
        open MODULE,    "<", $moduleFile;
        open NEWMODULE, ">", "$moduleFile.new";
        while (<MODULE>) {
            my $line    = $_;
            my $qmParam = quotemeta($pParam);
            if ( $line =~ /^$qmParam(:?)\t/ ) {
                $line = "$pParam$1	$pValue\n";
            }
            print NEWMODULE $line;
        }
        close MODULE;
        close NEWMODULE;

        # Move the new file into place
        `mv $moduleFile.new $moduleFile`;

        print STDOUT "  $patch\n";
    }

    my $runningTasks = 0;

    for my $inputFile (@inputs) {
        my $pid;
        if ( $pid = fork ) {

            # Increment running tasks counter
            $runningTasks++;

            # Kick off another task if we have slots
            next if ( $runningTasks < $opts{maxTasks} );

            # If not, wait for a child to terminate
            wait();

            # Decrement tasks counter to free its slot
            $runningTasks--;

            # Kick off another task
            next;
        }

        ( my $filename = $inputFile ) =~ s/.*\/([^\/]+\.stl)/$1/;

        print VERBOSE "Creating output directory for $filename/$profile...\n";
        `mkdir -p "$opts{output}/$filename/$profile"`;

        print VERBOSE "Copying input file to output structure...\n";
        `cp $inputFile $opts{output}/$filename/$profile/$filename`;

        print STDOUT "Skeining $inputFile (profile: $profile)...\n";
        `python $sfdir/skeinforge_utilities/skeinforge_craft.py $opts{output}/$filename/$profile/$filename >> $opts{output}/$filename/$profile/$filename.log`;
        print STDOUT "  Done skeining $inputFile (profile: $profile)\n";

        print VERBOSE "Cleaning up extra stl files...\n";
        `rm $opts{output}/$filename/$profile/$filename`;

        exit;

    }

    # Loop in case we have additional tasks running for some reason
    1 while ( wait() != -1 );

    # Restore profile configuration files if we patched anything
    for my $patch (@patches) {
        my ( $pProfile, $pModule, $pParam, $pValue ) = split /:/, $patch;
        next unless ( $pProfile eq $profile );

        my $dotsfdir
            = -d '/Users'
            ? "/Users/" . getlogin() . "/.skeinforge"
            : "/home/" . getlogin() . "/.skeinforge";

        my $moduleFile
            = -e "$dotsfdir/profile/extrusion/$pModule.csv"
            ? "$dotsfdir/profiles/extrusion/$profile/$pModule.csv"
            : "$sfdir/profiles/extrusion/$profile/$pModule.csv";

        if ( -e "$moduleFile.bak" ) {
            print STDOUT "Restoring patched config: $pModule...\n";
            `mv $moduleFile.bak $moduleFile`;
        }
    }

}

# Restore backed-up extrusion.csv
print VERBOSE "Restoring $profileFile...\n";
`mv $profileFile.bak $profileFile`;

print STDOUT "Done.\n";

0;

sub SIGINT {
    print STDOUT "Caught SIGINT, cleaning up...\n";
    `mv $profileFile.bak $profileFile`;
    exit 2;
}
