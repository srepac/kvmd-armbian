#!/bin/bash
# Written by srepac for PiKVM project
#
# This script checks what platform is installed on PiKVM (lots of users install wrong platform)
# Also, it will then check to make sure capture card is connected properly to the correct port
# ... and report any issues and possible resolutions.
#
function check-audio-support() {
  printf "\n+ Checking for Audio OUT and Mic IN support\n"
  TMPFILE="/tmp/ustreamer.jcfg"; /bin/rm -f $TMPFILE
  printf "\n--- /boot/config.txt excerpt ---\n"
  grep -i tc358743-audio /boot/config.txt
  printf "\n--- /etc/kvmd/janus/janus.plugin.ustreamer.jcfg excerpt ---\n"
  cat /etc/kvmd/janus/janus.plugin.ustreamer.jcfg | grep -A3 -E 'aplay|acap' > $TMPFILE; cat $TMPFILE
  EDIDCONF="/tmp/kvmd-edidconf.tmp"; /bin/rm -f $EDIDCONF
  kvmd-edidconf 2> $EDIDCONF
  printf "\n--- EDID ---\n"
  cat $EDIDCONF; echo

  if [ $( grep -ci tc358743-audio /boot/config.txt ) -ge 1 ]; then
    if [[ $( grep Audio $EDIDCONF | awk '{print $2}' ) == "yes" ]]; then
      echo "+ EDID supports audio."
    else
      echo "*** EDID DOES NOT support audio. ***"
      let warning=warning+1
    fi

    if [ $( grep -A3 acap: $TMPFILE | grep -c 'tc358743' ) -ge 1 ]; then
        echo "+ Audio OUT from target is ENABLED.  HINT: acap + tc358743 entries exist."
    else
      echo "*** Audio OUT from target is DISABLED.  HINT: acap entry missing ***"
      let warning=warning+1
    fi

    if [ $( grep -ci uac $TMPFILE ) -ge 1 ]; then
      echo "+ Mic IN to target is ENABLED.  HINT: aplay + UAC entries exist."
    else
      echo "*** Mic IN to target is DISABLED.  HINT: aplay entry missing ***"
      let warning=warning+1
    fi
  else
    echo "*** Missing AUDIO support altogether.  See https://docs.pikvm.org/audio to enable audio support. ***"
    let warning=warning+1
  fi
} # end function


### Check for Audio out and mic support for archlinux arm running on rpi hardware
WHOAMI=`whoami`
if [[ "$WHOAMI" != "root" ]]; then
  echo "$WHOAMI, you must be root to run this."
  exit 1
fi

csiflag=0
errors=0
warning=0
ARCHLINUX=$( grep PRETTY /etc/os-release | grep -c Arch )
UDEVRULESPATH="/usr/lib/udev/rules.d"     # PiKVM changed to this path recently 4.100+
if [ $ARCHLINUX -eq 1 ]; then
  SEARCH="1-1.4"        # use only port 1-1.4 on arch linux pikvm
  PLATFORM=$( pacman -Q | grep kvmd-platform | cut -d'-' -f3,4,5 | sed 's/ /  /g' )
else
  #SEARCH="MACRO"        # any port on anything other than arch pikvm
  SEARCH="UVC"          # any port on anything other than arch pikvm
  # Show kvmd-platform version for raspbian pikvm on rpi4
  v2v3=$( grep platform /var/cache/kvmd/installed_ver.txt | cut -d'-' -f3 | tail -1 )
  if [[ ! -e $UDEVRULESPATH/99-kvmd.rules ]]; then
    UDEVRULESPATH="/etc/udev/rules.d"     # default location for kvmd < 4.100
  fi
  if [[ $( grep video $UDEVRULESPATH/99-kvmd.rules | grep -c hdmiusb ) -gt 0 ]]; then
    platform="v2-hdmiusb-rpi4"
  else
    platform="${v2v3}-hdmi-rpi4"
  fi
  
  PLATFORM="$platform  $( grep kvmd-platform /var/cache/kvmd/installed_ver.txt | tail -1 | awk '{print $4}' | awk -F\- '{print $NF}')"
fi

echo "kvmd-platform/installed version:  ${PLATFORM}"
echo

echo "+ Checking for KB, VID, and MOUSE symlinks..."
KVMDEVS="/tmp/kvmdevs.txt"; rm -f $KVMDEVS
ls -l /dev/kvmd* > $KVMDEVS                             # check for kb/mouse/video
STATUS="Found"
if [ $( grep -c hid' ' $KVMDEVS ) -ge 1 ]; then
  STATUS="$STATUS Serial keyboard mouse"
else
  if [ $( grep -c keyboard $KVMDEVS ) -ge 1 ]; then
    STATUS="$STATUS OTG keyboard"
  else
    STATUS="$STATUS <missing kb>"
    let errors=errors+1
  fi
  if [ $( grep -c mouse $KVMDEVS ) -ge 1 ]; then
    STATUS="$STATUS mouse"
  else
    STATUS="$STATUS <missing mouse>"
    let errors=errors+1
  fi
fi
if [ $( grep -c video $KVMDEVS ) -ge 1 ]; then
  STATUS="$STATUS + video"
else
  STATUS="$STATUS + <missing video>"
  let errors=errors+1
fi
echo "+ $STATUS"; cat $KVMDEVS
echo

echo "+ Checking for capture device..."
HDMIUSB=$( grep video $UDEVRULESPATH/99-kvmd.rules | grep -c hdmiusb )
if [ $HDMIUSB -ge 1 ]; then
  # Make sure MACROSILICON controller on USB-HDMI is plugged in to 1-1.4
  # show the last MACROSILICON entry in case user moved the usb dongle
  # ... this way, script will always give the most recent check
  # ... NOTE:  You can move usb dongle anytime without powering down Pi
  if [ ! -e /var/log/dmesg ]; then
    USBHDMI=$( dmesg | grep -i $SEARCH | grep 'usb ' | tail -1 )
  else
    USBHDMI=$( grep -i $SEARCH /var/log/dmesg | grep 'usb ' | tail -1 )
  fi
  if [[ $( echo $USBHDMI | grep -c $SEARCH ) -gt 0 ]]; then
    printf "+ USB HDMI dongle is connected properly\n"
    echo "$USBHDMI"
    echo
    echo "*NOTE:  USB HDMI max supported resolution is 4k 30Hz downsampled to 1080p for PiKVM"
  else
    printf "x Pls put USB HDMI dongle to bottom USB2.0 port on Pi4 OR any USB port on non RPi SBC.\n"
    let errors=errors+1
  fi
else
  csiflag=1
  # PiKVM uses CSI bridge capture so check to make sure it's in the CAMERA port
  # ... NOTE:  Poweroff Pi before moving CSI cable
  CSI=$( dmesg | grep tc35 | grep -E -v -i 'Dependency|Modules' )
  if [[ $( echo $CSI | grep -c not ) -gt 0 ]]; then
    printf "x Check CSI cable is properly connected to Pi Camera port.\n"
    let errors=errors+1
  else
    printf "+ CSI 2 HDMI bridge is connected properly\n"
  fi
  echo "$CSI"; echo

  echo "+ Checking for what resolution the target is sending..."
  DVTIMINGS="/tmp/dvtimings.txt"
  v4l2-ctl --query-dv-timings  > $DVTIMINGS    # look for active width/height and pixelclock
  HEIGHT=$( grep Active $DVTIMINGS | grep height | awk '{print $NF}')
  WIDTH=$( grep Active $DVTIMINGS | grep width | awk '{print $NF}')
  if [[ $HEIGHT -eq 0 && $WIDTH -eq 0 ]]; then
    echo "*** < NO SIGNAL > from target.  Check/replace HDMI cable or power ON target. ***"
    let errors=errors+1
  else
    HZ=$( grep Pixelclock $DVTIMINGS | awk -F\( '{print $2}' | cut -d' ' -f1 )
    echo "+ Active Target resolution:  ${WIDTH}x${HEIGHT} ${HZ}Hz"
    cat $DVTIMINGS | grep -E 'width|height|Pixel' | grep -v Total
  fi

  echo
  echo "* NOTE1:  CSI builds with Pi Zero (2) W or Pi4B max supported resolution: 720p 60Hz + 1080p 50Hz"
  echo "* NOTE2:  CSI builds with Compute Module 4 max supported resolution: 1080p 60Hz + 1920x1200 60Hz"
fi
printf "\n--- KNOW THE LIMITS AND MAKE SURE TARGET RESOLUTIONS STAY WITHIN THOSE LIMITS ---\n"

echo
### show error status message regarding basic K V + M support
if [ $errors -gt 0 ]; then
  echo "-> Found $errors error(s).  Please fix then try again."
else
  echo "=== Congratulations, $errors errors found.  If you are having issues with K V or M, then check hardware/cables."
fi

if [ $csiflag -eq 1 ]; then
  OS=$( grep ^ID= /etc/os-release | cut -d= -f2 )
  case $OS in
    arch*) check-audio-support;;
    ubuntu|debian|*) echo "*** Audio support is NON-existent for this $OS OS. ***"; exit 0;;
  esac
  ### show warning status message regarding AUDIO IN+OUT support.
  if [ $warning -gt 0 ]; then
    echo "-> Found $warning warning(s) about Audio IN + OUT support.  These are nice to have and do not affect KVM functionality."
  else
    echo "=== Congratulations, $warning warnings found.  Audio support IN + OUT should work properly."
  fi
fi
