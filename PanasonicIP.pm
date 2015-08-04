# ==========================================================================
#
# ZoneMinder Foscam FI8908W IP Control Protocol Module, $Date: 2009-11-25 09:20:00 +0000 (Wed, 04 Nov 2009) $, $Revision: 0001 $
# Copyright (C) 2001-2008 Philip Coombes
# Modified for use with Foscam FI8908W IP Camera by Dave Harris
# Updates for Iris, Contrast, Presets and code rewrite
# Copyright (C) 2011 Daniel Rich
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place – Suite 330, Boston, MA 02111-1307, USA.
#
# ==========================================================================
#
# This module contains the implementation of the Foscam FI8908W IP camera control
# protocol
#
package ZoneMinder::Control::FoscamFI8908W;

use 5.006;
use strict;
use warnings;

require ZoneMinder::Base;
require ZoneMinder::Control;

our @ISA = qw(ZoneMinder::Control);

our $VERSION = $ZoneMinder::Base::VERSION;

# Change these for your camera username/password
our $FCUser = “zone minder”;
our $FCPass = “oCJjs9gME1xu”;

our $FCMoveSleep = 0.50;    # Time to move before stopping
# Don’t chnage any values below here
our %FCParams = ();
our $FCDirection = undef;    # Direction we are currently moving
our %FCMove = ( “Up”         => [ 0, 1 ],
        “Down”       => [ 2, 3 ],
        “Right”      => [ 4, 5 ],
        “Left”       => [ 6, 7 ],
        “Up Right”   => [ 90, 1 ],
        “Up Left”    => [ 91, 1 ],
        “Down Right” => [ 92, 1 ],
        “Down Left”  => [ 93, 1 ],
        “Vertical Patrol” => [ 26, 27 ],
        “Horizon Patrol”  => [ 28, 29 ],
          );
our %FCControl = ( “Resolution”  => [ 0, { “320×240″ => 8,
                           “640×480″ => 32 } ],
           “Brightness”  => [ 1, undef ],
           “Contrast”    => [ 2, undef ],
           “Mode”        => [ 3, { “50Hz” => 0,
                              “60Hz” => 1,
                           “Outdoor” => 2 } ],
           “Flip/Mirror” => [ 5, { “Default” => 0,
                           “Flip”    => 1,
                           “Mirror”  => 2,
                           “Both”    => 3 } ],
         );

# ==========================================================================
#
# Foscam FI8908W IP Control Protocol
#
# ==========================================================================

use ZoneMinder::Debug qw(:all);
use ZoneMinder::Config qw(:all);

 use Time::HiRes qw( usleep );

sub new
{

my $class = shift;
my $id = shift;
my $self = ZoneMinder::Control->new( $id );
my $logindetails = “”;
bless( $self, $class );
srand( time() );
return $self;
}

our $AUTOLOAD;

sub AUTOLOAD
{
my $self = shift;
my $class = ref($self) || croak( “$self not object” );
my $name = $AUTOLOAD;
$name =~ s/.*://;
if ( exists($self->{$name}) )
{
return( $self->{$name} );
}
Fatal( “Can’t access $name member of object of class $class” );
}
our $stop_command;

sub open
{
my $self = shift;

$self->loadMonitor();

use LWP::UserAgent;
$self->{ua} = LWP::UserAgent->new;
$self->{ua}->agent( “ZoneMinder Control Agent/”.ZM_VERSION );

$self->{state} = ‘open';
$self->getFCParams();
}

sub close
{ 
my $self = shift;
$self->{state} = ‘closed';
}

sub printMsg
{
    my($self,$msg) = @_;

    if ( zmDbgLevel() > 0 )
    {
        my $self = shift;
        my $msg = shift;
        my $prefix = shift || “”;
        $prefix = $prefix.”: ” if ( $prefix );

        my $line_length = 16;
        my $msg_len = int(@$msg);

        my $msg_str = $prefix;
        for ( my $i = 0; $i < $msg_len; $i++ )
        {
            if ( ($i > 0) && ($i%$line_length == 0) && ($i != ($msg_len-1)) )
            {
                $msg_str .= sprintf( “\n%*s”, length($prefix), “” );
            }
            $msg_str .= sprintf( “%02x “, $msg->[$i] );
        }
        $msg_str .= “[“.$msg_len.”]”;
        Debug( $msg_str );
    }
}

sub getFCParams
{
  my $self = shift;

  my $req = HTTP::Request->new( GET=>”http://”.$self->{Monitor}->{ControlAddress}.”/get_camera_params.cgi?user=$FCUser&pwd=$FCPass” );
  my $res = $self->{ua}->request($req);

  if ( $res->is_success ) {
    # Parse results setting values in %FCParams
    my $content = $res->decoded_content;
    while ($content =~ s/var\s+([^=]+)=([^;]+);//ms) {
      $FCParams{$1} = $2;
    }
  } else {
    Error( “Error check failed:'”.$res->status_line().”‘” );
  }
}

sub sendCmd
{
my $self = shift;
my $cmd = shift;
my $result = undef;
printMsg( $cmd, “Tx” );

my $req = HTTP::Request->new( GET=>”http://”.$self->{Monitor}->{ControlAddress}.”/$cmd” );
my $res = $self->{ua}->request($req);

if ( $res->is_success )
{
$result = !undef;
}
else
{
Error( “Error check failed:'”.$res->status_line().”‘” );
}

return( $result );
}

sub reset
{
my $self = shift;
Debug( “Camera Reset” );
my $cmd = “reboot.cgi?user=$FCUser&pwd=$FCPass”;
$self->sendCmd( $cmd );
}

# Camera control – giving a control options and possible arg, control the cam
sub controlCam
{
  my ($self, $params, $ctrl, $arg) = @_;

  unless (defined $FCControl{$ctrl}) {
    printMsg( “Control $ctrl: control unknown” );
    return;
  }
  my $param = $FCControl{$ctrl}[0];
  my $val = $arg;
  if ($FCControl{$ctrl}[1] eq “HASH”) {
    unless (defined $FCControl{$ctrl}{$arg}) {
      printMsg( “Control $ctrl-$arg: control unknown” );
      return;
    }
    $val = $FCControl{$ctrl}[1]{$arg};
  }
  Debug( “Control $ctrl $arg” );
  my $cmd = “camera_control.cgi?param=$param&value=$val&user=$FCUser&pwd=$FCPass”;
  $self->sendCmd( $cmd );
}

# Camera movement – given a direction, move the camera that way
sub moveCam
{
  my($self,$params, $dir) = @_;

  unless (defined $FCMove{$dir}) {
    printMsg( “Move $dir: direction unknown” );
    return;
  }
  my $autostop = $self->getParam( $params, ‘autostop’, 0 );
  my $orientation = $self->getParam( $params, ‘orientation’, 0 );
  Debug( “Move $dir ($autostop, $orientation)” );
  $self->moveStop if ($FCDirection);
  $FCDirection = $dir;
  my $val=$FCMove{$FCDirection}[0];
  my $cmd = “decoder_control.cgi?command=$val&user=$FCUser&pwd=$FCPass”;
  $self->sendCmd( $cmd );
  if( $autostop && $self->{Monitor}->{AutoStopTimeout} )
  {
    Debug( “Move autostopping in $autostop s.” );
    usleep( $self->{Monitor}->{AutoStopTimeout} );
    $self->moveStop;
  }
}

#Up Arrow
sub Up
{
  my($self,$params) = @_;
  $self->moveConUp($params);
  usleep( $FCMoveSleep );
  $self->moveStop;
}
sub moveConUp
{
  my($self,$params) = @_;
  $self->moveCam($params,’Up’);
}

#Down Arrow
sub Down
{
  my($self,$params) = @_;
  $self->moveConDown($params);
  usleep( $FCMoveSleep );
  $self->moveStop;
}
sub moveConDown
{
  my($self,$params) = @_;
  $self->moveCam($params,’Down’);
}

#Left Arrow
sub Left
{
  my($self,$params) = @_;
  $self->moveConLeft($params);
  usleep( $FCMoveSleep );
  $self->moveStop;
}
sub moveConLeft
{
  my($self,$params) = @_;
  $self->moveCam($params,’Left’);
}

#Right Arrow
sub Right
{
  my($self,$params) = @_;
  $self->moveConRight($params);
  usleep( $FCMoveSleep );
  $self->moveStop;
}
sub moveConRight
{
  my($self,$params) = @_;
  $self->moveCam($params,’Right’);
}

#Diagonally Up Right Arrow
sub UpRight
{
  my($self,$params) = @_;
  $self->moveConUpRight($params);
  usleep( $FCMoveSleep );
  $self->moveStop;
}
sub moveConUpRight
{
  my($self,$params) = @_;
  $self->moveCam($params,’Up Right’);
}

#Diagonally Down Right Arrow
sub DownRight
{
  my($self,$params) = @_;
  $self->moveConDownRight($params);
  usleep( $FCMoveSleep );
  $self->moveStop;
}
sub moveConDownRight
{
  my($self,$params) = @_;
  $self->moveCam($params,’Down Right’);
}

#Diagonally Up Left Arrow
sub UpLeft
{
  my($self,$params) = @_;
  $self->moveConUpLeft($params);
  usleep( $FCMoveSleep );
  $self->moveStop;
}
sub moveConUpLeft
{
  my($self,$params) = @_;
  $self->moveCam($params,’Up Left’);
}

#Diagonally Down Left Arrow
sub DownLeft
{
  my($self,$params) = @_;
  $self->moveConDownLeft($params);
  usleep( $FCMoveSleep );
  $self->moveStop;
}
sub moveConDownLeft
{
  my($self,$params) = @_;
  $self->moveCam($params,’Down Left’);
}

#Stop
sub moveStop
{
  my($self,$params) = @_;
  Debug( “Move Stop” );
  my $val = 1;
  if ($FCDirection) {
    $val=$FCMove{$FCDirection}[1];
  }
  my $cmd = “decoder_control.cgi?command=$val&user=$FCUser&pwd=$FCPass”;
  $self->sendCmd( $cmd );
  $FCDirection = undef;
}

#Move Camera to Home Position
sub presetHome
{
  my($self,$params) = @_;
  Debug( “Home Preset” );
  my $cmd = “decoder_control.cgi?command=25&user=$FCUser&pwd=$FCPass”;
  $self->sendCmd( $cmd );
}

# Brightness/Contrast
sub irisAbsOpen
{
    my ($self,$params,$val) = @_;
    $self->getFCParams() unless($FCParams{‘brightness’});
    my $step = $self->getParam( $params, ‘step’ );
    $FCParams{‘brightness’} += $step;
    $FCParams{‘brightness’} = 255 if ($FCParams{‘brightness’} > 255);
    Debug( “Iris $FCParams{‘brightness’}” );
    $self->controlCam($params,”Brightness”,$FCParams{‘brightness’});
}
sub irisAbsClose
{
    my ($self,$params,$val) = @_;
    $self->getFCParams() unless($FCParams{‘brightness’});
    my $step = $self->getParam( $params, ‘step’ );
    $FCParams{‘brightness’} -= $step;
    $FCParams{‘brightness’} = 0 if ($FCParams{‘brightness’} < 0);
    Debug( “Iris $FCParams{‘brightness’}” );
    $self->controlCam($params,”Brightness”,$FCParams{‘brightness’});
}

sub whiteAbsIn
{
    my ($self,$params) = @_;
    $self->getFCParams() unless($FCParams{‘contrast’});
    my $step = $self->getParam( $params, ‘step’ );
    $FCParams{‘contrast’} += $step;
    $FCParams{‘contrast’} = 6 if ($FCParams{‘contrast’} > 6);
    Debug( “White $FCParams{‘contrast’}” );
    $self->controlCam($params,”Contrast”,$FCParams{‘contrast’});
}
sub whiteAbsOut
{
    my ($self,$params) = @_;
    $self->getFCParams() unless($FCParams{‘contrast’});
    my $step = $self->getParam( $params, ‘step’ );
    $FCParams{‘contrast’} -= $step;
    $FCParams{‘contrast’} = 0 if ($FCParams{‘contrast’} < 0);
    Debug( “White $FCParams{‘contrast’}” );
    $self->controlCam($params,”Contrast”,$FCParams{‘contrast’});
}

# Presets
sub presetSet
{
  my($self,$params) = @_;
  my $preset = $self->getParam( $params, ‘preset’, 1 );
  Debug( “Set Preset $preset” );
  my $val = 30 + ($preset * 2);    # set preset 0 is 30
  my $cmd = “decoder_control.cgi?command=$val&user=$FCUser&pwd=$FCPass”;
  $self->sendCmd( $cmd );
}
sub presetGoto
{
  my($self,$params) = @_;
  my $preset = $self->getParam( $params, ‘preset’, 1 );
  Debug( “Goto Preset $preset” );
  my $val = 31 + ($preset * 2);    # go preset 0 is 31
  my $cmd = “decoder_control.cgi?command=$val&user=$FCUser&pwd=$FCPass”;
  $self->sendCmd( $cmd );
}
1;

__END__