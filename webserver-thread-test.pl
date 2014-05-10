#!/usr/bin/perl

# Copyright (C) 2014 Bernd Arnold
# Licensed under GPLv2
# See file LICENSE for more information
#
# https://github.com/wopfel/archlinux-setup-vb

use strict;
use warnings;
use threads;
use HTTP::Daemon;
use HTTP::Status qw(:constants);
use utf8;




# Track state of virtual machine
my %vm_state;


# Works with a german keyboard

my %scanmap;

#
# Base keys (without shift modifier key)
#

my $basemap = '
0x02::1234567890ß´
0x10::qwertzuiopü+
0x1e::asdfghjklöä#
0x2b::<yxcvbnm,.-';

for ( split /\n/, $basemap ) {

    if ( /^0x(..)::(.*)$/ ) {
        my $offset = $1;
        my $keys = $2;
        my $nr = 0;
        for my $key ( split //, $keys ) {
            #print "[ $key ]";
            $scanmap{ $key } = sprintf "%02x %02x", (hex($offset) + $nr), (hex($offset) + $nr + 128);
            $nr++;
        }
    }
}


#
# "Uppercase" keys (with shift modifier key)
#

my $uppermap = q,
0x02::!"§$%&/()=?`
0x10::QWERTZUIOPÜ*
0x1e::ASDFGHJKLÖÄ'
0x2b::>YXCVBNM;:_,;

for ( split /\n/, $uppermap ) {

    if ( /^0x(..)::(.*)$/ ) {
        my $offset = $1;
        my $keys = $2;
        my $nr = 0;
        for my $key ( split //, $keys ) {
            #print "[ $key ]";
            $scanmap{ $key } = sprintf "2a %02x %02x aa", (hex($offset) + $nr), (hex($offset) + $nr + 128);
            $nr++;
        }
    }
}

# Credits to: http://www.marjorie.de/ps2/scancode-set1.htm
$scanmap{ "<LT>" }       = "56 d6";
$scanmap{ "<GT>" }       = "2a 56 d6 aa";
$scanmap{ "<SPACE>" }    = "39 b9";
$scanmap{ " " }          = $scanmap{ "<SPACE>" };
$scanmap{ "{" }          = "e0 38 08 88 e0 b8";
$scanmap{ "}" }          = "e0 38 0b 8b e0 b8";
$scanmap{ "[" }          = "e0 38 09 89 e0 b8";
$scanmap{ "]" }          = "e0 38 0a 8a e0 b8";
$scanmap{ "#" }          = "2b ab";
$scanmap{ "<ENTER>" }    = "1c 9c";
$scanmap{ "<ARROW-DOWN>" }    = "e0 50 e0 d0";
$scanmap{ "<ARROW-LEFT>" }    = "e0 4b e0 cb";
$scanmap{ "<ARROW-UP>" }      = "e0 48 e0 c8";
$scanmap{ "<ARROW-RIGHT>" }   = "e0 4d e0 cd";


sub send_keys_to_vm {

    # You can run `showkey --scancodes` on a console to view the scancodes

    my $string = shift;
    my @scancodes = ();

    while ( length $string > 0 ) {

        # First part: <SPECIAL> keys
        # Second part: default keys, like 'q', 'w', ..., 'Q', ...
        if ( $string =~ /^(<.*?>)(.*)$/ ) {
            my $key = $1;
            $string = $2;

            if ( defined $scanmap{ $1 } ) {
                push @scancodes, $scanmap{ $1 };
            } elsif ( $key eq "<WAIT_PAUSE>" ) {
                # Inserts a pause before firing the next keystrokes
                push @scancodes, "WAIT_PAUSE";
            } else {
                print STDERR "Error: missing scancode for special '$key'!";
                die;
            }
            #print "=== $1 ===\n";
            #print "=== $2 ===\n";
        } elsif ( $string =~ /^(.)(.*)$/ ) {
            my $key = $1;
            $string = $2;
            #print "=== $1 ===\n";
            #print "=== $2 ===\n";
            if ( $key =~ /^(<|>)$/ ) {
                print STDERR "Error: Lonely '$key' found. Use <LT> and <GT> for single '<'/'>' keys!";
                die;
            }
            if ( defined $scanmap{ $1 } ) {
                push @scancodes, $scanmap{ $1 };
            } else {
                print STDERR "Error: missing scancode for key '$key'!";
                die;
            }
        }
        #print "==========\n";
    }


    # The command mustn't be too long, otherwise vboxmanage complains with the following message:
    # error: Could not send all scan codes to the virtual keyboard (VERR_PDM_NO_QUEUE_ITEMS)
    # To avoid this the scancodes are split and passed in several vboxmanage commands

    # Some commands seem to empty the keyboard buffer before reading new keys
    # For this, <WAIT_PAUSE> (which was translated to WAIT_PAUSE) can be used which delays the next keystrokes


    # While there are elements in the array...
    while ( scalar @scancodes > 0 ) {

        # Check if the first element tells us to wait
        if ( $scancodes[0] eq "WAIT_PAUSE" ) {
            # Sleep some time
            #print "Sleeping.\n";
            sleep 2;
            # Remove element and retry loop
            shift @scancodes;
            next;
        }

        # The maximum number of elements for splice
        my $max_elements;

        # Check if there's a "WAIT_PAUSE" awaiting us
        # Beginning with 1, since the first element cannot be "WAIT_PAUSE"
        for my $i ( 1..9 ) {

            # Exit the loop if end is reached
            last unless defined $scancodes[$i];

            # Check for pause instruction
            if ( $scancodes[$i] eq "WAIT_PAUSE" ) {
                # Not "+ 1", so WAIT_PAUSE is left in the array
                $max_elements = $i;
            }

        }

        # Defaults to 10
        $max_elements ||= 10;

        # Get the first $max_elements scancodes (note: in this context, one scancode could be "26 a6")
        my @subset = splice( @scancodes, 0, $max_elements );

        # Join all 2-digit scancodes using a blank (" ")
        my $scancodes = join " ", @subset;

        # Call vboxmanage
        # Blanks are not allowed, so the joined $scancodes doesn't work, vboxmanage complains with "Error: '...' is not a hex byte!"
        my @args = ( "vboxmanage", "controlvm", "{f57aeae8-bc2c-47c3-9b65-f5822f8b47ef}",
                     "keyboardputscancode",
                     split( / /, $scancodes )
                   );

        #print "@args\n";
        system( @args ) == 0  or  die "Error: system call (@args) failed";

    }

}



sub process_client_request {

    #print "Processing request.\n";

    my $c = shift;
    my $r = $c->get_request;

    if ($r) {
        #print "URI: ", $r->uri->path, "\n";
        #print "URL: ", $r->url->path, "\n";

        # /vmstatus/CURRENTVM/alive
        if ( $r->method eq "GET"  and  $r->url->path =~ m"^/vmstatus/CURRENTVM/alive$" ) {
            # Maybe we're handling more than one VM at the same time, so CURRENTVM is for future enhancements
            print "VM is alive!\n";
            # Send back status code 200: OK
            $c->send_status_line( 200 );
            # Store current time
            $vm_state{'CURRENTVM'}{'alive_msg'} = time;
        }
        # http://10.0.2.2:8080/vmstatus/CURRENTVM/step/$step/returncode/\$?
        elsif ( $r->method eq "GET"  and  $r->url->path =~ m"^/vmstatus/CURRENTVM/step/(\d+)/returncode/(\d+)$" ) {
            # Assuming only positive returncodes (\d+)
            # Maybe we're handling more than one VM at the same time, so CURRENTVM is for future enhancements
            my $stepnr = $1;
            my $returncode = $2;
            print "VM reported return code: $returncode. Finished step number: $stepnr.\n";
            # Send back status code 200: OK
            $c->send_status_line( 200 );
            # Store return code and step information
            $vm_state{'CURRENTVM'}{'last_completed_step_nr'} = $stepnr;
            $vm_state{'CURRENTVM'}{'last_completed_step_rc'} = $returncode;
            $vm_state{'CURRENTVM'}{'last_completed_step_time'} = time;
            $vm_state{'CURRENTVM'}{'steplist'}{$stepnr}{'rc'} = $returncode;
            $vm_state{'CURRENTVM'}{'steplist'}{$stepnr}{'time'} = $vm_state{'CURRENTVM'}{'last_completed_step_time'};
        } else {
            $c->send_error( 501, "Too early. Function not implemented yet." );
        }
        #if ($r->method eq "GET") {
        #    my $path = $r->url->path();
        #    $c->send_file_response($path);
        #    #or do whatever you want here
        #}
    } else {
        $c->send_error( HTTP_FORBIDDEN );
    }

    $c->close;
    undef( $c );

}


sub http_thread {

    my $daemon = HTTP::Daemon->new(
                                    LocalPort => 8080,
                                    Listen => 20
                                  );

    die unless $daemon;

    print "Embedded web server started.\n";
    print "Server address: ", $daemon->sockhost(), "\n";
    print "Server port: ",    $daemon->sockport(), "\n";

    # Wait for client requests
    while ( my $c = $daemon->accept ) {
        threads->create( \&process_client_request, $c )->detach();
    }

    # TODO: Reach this point the "normal" way (how to exit the previous while loop?)

    print "Embedded web server ends.\n";

}


# No output buffering
$| = 1;

my $thread = threads->create( 'http_thread' );

print "Program started.\n";

my @vm_steps = (
                 {
                   command => "loadkezs deßlatin1<ENTER>",
                 },
                 {
                   command => 'kill ${${(v)jobstates#*:*:}%=*}<ENTER>',
                   description => "Killing all background jobs (easier for testing when the program is restarted frequently)",
                 },
                 {
                   command => "curl http://10.0.2.2:8080/vmstatus/CURRENTVM/alive<ENTER>",
                 },
                 {
                   command => "while true ; do curl http://10.0.2.2:8080/vmstatus/CURRENTVM/alive 1<GT> /dev/null 2<GT>&1 ; sleep 2 ; done &<ENTER>",
                   description => "Background loop to let us know the VM is alive",
                 },
                 {
                   command => "cfdisk /dev/sda",
                   subcommand => "<WAIT_PAUSE>" .                 # Insert a pause before continuing
                                 "<ENTER>" .                      # New partition
                                 "<ENTER>" .                      # Primary
                                 "100<ENTER>" .                   # MB
                                 "<ENTER>" .                      # Beginning
                                 "<ENTER>" .                      # Bootable
                                 "<WAIT_PAUSE>" .                 # Insert a pause before continuing
                                 "<ARROW-DOWN>" .                 # Free space
                                 "<ENTER>" .                      # New partition
                                 "<ENTER>" .                      # Primary
                                 "<ENTER>" .                      # Default size
                                 "<ARROW-LEFT>" .                 # Highlight Write
                                 "<ENTER>" .                      # Write
                                 "yes<ENTER>" .
                                 "<WAIT_PAUSE>" .                 # Insert a pause before continuing
                                 "<ARROW-LEFT><ARROW-LEFT>" .     # Highlight Units
                                 "<ARROW-LEFT><ARROW-LEFT>" .     # Highlight Quit
                                 "<ENTER>",                       # Quit
                   requestrc => 1,
                 },
                 {
                   command => "cryptsetup -c aes-xts-plain64 -y -s 512 luksFormat /dev/sda2",
                   subcommand => "<WAIT_PAUSE>" .                 # Insert a pause before continuing
                                 "YES<ENTER>" .
                                 "<WAIT_PAUSE>" .
                                 "arch<ENTER>" .                  # The passphrase
                                 "<WAIT_PAUSE>" .
                                 "arch<ENTER>",                   # Verify the passphrase
                   requestrc => 1,
                 },
                 {
                   command => "cryptsetup luksOpen /dev/sda2 lvm",
                   subcommand => "arch<ENTER>",                   # The passphrase
                   requestrc => 1,
                 },
                 {
                   command => "pvcreate /dev/mapper/lvm",
                   requestrc => 1,
                 },
                 {
                   command => "vgcreate main /dev/mapper/lvm",
                   requestrc => 1,
                 },
                 {
                   command => "lvcreate -L 2GB -n root main",
                   requestrc => 1,
                 },
                 {
                   command => "lvcreate -L 2GB -n swap main",
                   requestrc => 1,
                 },
                 {
                   command => "lvcreate -L 2GB -n home main",
                   requestrc => 1,
                 },
                 {
                   command => "lvs",
                   requestrc => 1,
                 },
                 {
                   command => "mkfs.ext4 -L root /dev/mapper/main-root",
                   requestrc => 1,
                 },
                 {
                   command => "mkfs.ext4 -L home /dev/mapper/main-home",
                   requestrc => 1,
                 },
                 {
                   command => "mkfs.ext4 -L boot /dev/sda1",
                   requestrc => 1,
                 },
                 {
                   command => "mkswap -L swap /dev/mapper/main-swap",
                   requestrc => 1,
                 },
                 {
                   command => "mount /dev/mapper/main-root /mnt",
                   requestrc => 1,
                 },
                 {
                   command => "mkdir /mnt/home",
                   requestrc => 1,
                 },
                 {
                   command => "mount /dev/mapper/main-home /mnt/home",
                   requestrc => 1,
                 },
                 {
                   command => "mkdir /mnt/boot",
                   requestrc => 1,
                 },
                 {
                   command => "mount /dev/sda1 /mnt/boot",
                   requestrc => 1,
                 },
                 {
                   command => "pacstrap /mnt base base-devel syslinux",
                   requestrc => 1,
                 },
               );


for my $step ( 0 .. $#vm_steps ) {

    # For easier access ($step{key} instead of ${ $vm_steps[$step] }{key})
    my %step = %{ $vm_steps[$step] };

    print "Starting step $step...\n";

    # Send command to virtual machine
    send_keys_to_vm( $step{'command'} );

    # Send "submitting the return code" command to virtual machine if requested
    send_keys_to_vm( " ; curl http://10.0.2.2:8080/vmstatus/CURRENTVM/step/$step/returncode/\$?" )  if  $step{'requestrc'};

    # Send enter key to virtual machine
    send_keys_to_vm( "<ENTER>" );

    # Sleeping 1 second
    sleep 1;

    # Send subcommand to virtual machine
    send_keys_to_vm( $step{'subcommand'} )  if  defined $step{'subcommand'};

    # Sleeping 1 second
    sleep 1;

    # Wait for successful completion
    if ( $step{'requestrc'} ) {

        # TODO: exit loop after timeout
        while (1) {
            printf "Last step completed: %d, return code: %d.\n", $vm_state{'CURRENTVM'}{'last_completed_step_nr'},
                                                                  $vm_state{'CURRENTVM'}{'last_completed_step_rc'};
            last if $vm_state{'CURRENTVM'}{'last_completed_step_nr'} == $step  and
                    $vm_state{'CURRENTVM'}{'last_completed_step_rc'} == 0;
            sleep 1;
        }

    }

}

# Wait 10 minutes so pacstrap can finish the installation (hopefully done in 10 minutes)
sleep 10*60;

# Kill all background jobs (for example, the I'm-alive loop we've started previously
# From: http://stackoverflow.com/questions/13166544/how-to-kill-all-background-processes-in-zsh
send_keys_to_vm( 'kill ${${(v)jobstates#*:*:}%=*}' ); #<ENTER>" );


sleep 60;

threads->exit();

exit 0;

