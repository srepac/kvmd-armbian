#!/bin/bash
# https://github.com/srepac/kvmd-armbian
#
# modified by xe5700            2021-11-04      xe5700@outlook.com
# modified by NewbieOrange      2021-11-04
# created by @srepac   08/09/2021   srepac@kvmnerds.com
# Scripted Installer of Pi-KVM on Armbian 32-bit and 64-bit (as long as it's running python 3.10 or higher)
#
# *** MSD is disabled by default ***
#
# Mass Storage Device requires the use of a USB thumbdrive or SSD and will need to be added in /etc/fstab
: '
# SAMPLE /etc/fstab entry for USB drive with only one partition formatted as ext4 for the entire drive:

/dev/sda1  /var/lib/kvmd/msd   ext4  nodev,nosuid,noexec,ro,errors=remount-ro,data=journal,X-kvmd.otgmsd-root=/var/lib/kvmd/msd,X-kvmd.otgmsd-user=kvmd  0  0

'
# NOTE:  This was tested on a new install of raspbian desktop and lite versions, but should also work on an existing install.
#
# Last change 20240526 2345 PDT
VER=3.4
set +x
PIKVMREPO="https://files.pikvm.org/repos/arch/rpi4"
KVMDFILE="kvmd-3.291-1-any.pkg.tar.xz"
KVMDCACHE="/var/cache/kvmd"; mkdir -p $KVMDCACHE
PKGINFO="${KVMDCACHE}/packages.txt"
APP_PATH=$(readlink -f $(dirname $0))
LOGFILE="${KVMDCACHE}/installer.log"; touch $LOGFILE; echo "==== $( date ) ====" >> $LOGFILE

cm4=0   # variable to take care of CM4 specific changes
csisvc=0  # variable to take care of starting CSI specific services

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  echo "usage:  $0 [-f]   where -f will force re-install new pikvm platform"
  exit 1
fi

CWD=`pwd`

WHOAMI=$( whoami )
if [ "$WHOAMI" != "root" ]; then
  echo "$WHOAMI, please run script as root."
  exit 1
fi

PYTHONVER=$( python3 -V | cut -d' ' -f2 | cut -d'.' -f1,2 )
case $PYTHONVER in
  3.1[0-9])
    echo "Python $PYTHONVER is supported." | tee -a $LOGFILE
    ;;
  *)
    echo "Python $PYTHONVER is NOT supported.  Please make sure you have python3.10 or higher installed.  Exiting." | tee -a $LOGFILE
    exit 1
    ;;
esac

### added on 01/31/23 in case armbian is installed on rpi boards
if [ -e /boot/firmware/config.txt ]; then
  _BOOTCONF="/boot/firmware/config.txt"
else
  _BOOTCONF="/boot/config.txt"
fi

MAKER=$(tr -d '\0' < /proc/device-tree/model | awk '{print $1}')

press-enter() {
  echo
  read -p "Press ENTER to continue or CTRL+C to break out of script."
} # end press-enter

gen-ssl-certs() {
  cd /etc/kvmd/nginx/ssl
  openssl ecparam -out server.key -name prime256v1 -genkey
  openssl req -new -x509 -sha256 -nodes -key server.key -out server.crt -days 3650 \
        -subj "/C=US/ST=Denial/L=Denial/O=Pi-KVM/OU=Pi-KVM/CN=$(hostname)"
  cp server* /etc/kvmd/vnc/ssl/
  cd ${APP_PATH}
} # end gen-ssl-certs

enable-csi-svcs() {
  if [ ${csisvc} -eq 1 ]; then
    systemctl enable kvmd-tc358743 kvmd-janus-static
  fi
}

create-override() {
  if [ $( grep ^kvmd: /etc/kvmd/override.yaml | wc -l ) -eq 0 ]; then

    if [[ $( echo $platform | grep usb | wc -l ) -eq 1 ]]; then
      cat <<USBOVERRIDE >> /etc/kvmd/override.yaml
kvmd:
    hid:
        mouse_alt:
            device: /dev/kvmd-hid-mouse-alt  # allow relative mouse mode
    msd:
        type: disabled
    atx:
        type: disabled
    streamer:
        forever: true
        cmd_append:
            - "--slowdown"      # so target doesn't have to reboot
        resolution:
            default: 1280x720
USBOVERRIDE

    else

      cat <<CSIOVERRIDE >> /etc/kvmd/override.yaml
kvmd:
    ### disable fan socket check ###
    info:
        fan:
            unix: ''
    hid:
        mouse_alt:
            device: /dev/kvmd-hid-mouse-alt
    msd:
        type: disabled
    streamer:
        forever: true
        cmd_append:
            - "--slowdown"      # so target doesn't have to reboot
CSIOVERRIDE

    fi

  fi
} # end create-override

install-python-packages() {
  for i in $( echo "aiofiles aiohttp appdirs asn1crypto async-timeout bottle cffi chardet click
colorama cryptography dateutil dbus dev hidapi idna libgpiod mako marshmallow more-itertools multidict netifaces
packaging passlib pillow ply psutil pycparser pyelftools pyghmi pygments pyparsing requests semantic-version
setproctitle setuptools six spidev systemd tabulate urllib3 wrapt xlib yaml yarl pyotp qrcode serial " )
  do
    echo "apt-get install python3-$i -y" | tee -a $LOGFILE
    apt-get install python3-$i -y >> $LOGFILE
  done
} # end install python-packages

otg-devices() {
  modprobe libcomposite
  if [ ! -e /sys/kernel/config/usb_gadget/kvmd ]; then
    mkdir -p /sys/kernel/config/usb_gadget/kvmd/functions
    cd /sys/kernel/config/usb_gadget/kvmd/functions
    mkdir hid.usb0  hid.usb1  hid.usb2  mass_storage.usb0
  fi
  cd ${APP_PATH}
} # end otg-device creation

install-tc358743() {
  ### CSI Support for Raspbian ###
  #curl https://www.linux-projects.org/listing/uv4l_repo/lpkey.asc | apt-key add -
  #echo "deb https://www.linux-projects.org/listing/uv4l_repo/raspbian/stretch stretch main" | tee /etc/apt/sources.list.d/uv4l.list

  #apt-get update >> $LOGFILE
  #echo "apt-get install uv4l-tc358743-extras -y" | tee -a $LOGFILE
  #apt-get install uv4l-tc358743-extras -y >> $LOGFILE

  systemctl enable kvmd-tc358743 kvmd-janus-static
} # install package for tc358743

boot-files() {
  if [[ -e ${_BOOTCONF} && $( grep srepac ${_BOOTCONF} | wc -l ) -eq 0 ]]; then

    if [[ $( echo $platform | grep usb | wc -l ) -eq 1 ]]; then  # hdmiusb platforms

      cat <<FIRMWARE >> ${_BOOTCONF}
# srepac custom configs
###
hdmi_force_hotplug=1
gpu_mem=${GPUMEM}
enable_uart=1

#dtoverlay=tc358743

dtoverlay=disable-bt
dtoverlay=dwc2,dr_mode=peripheral
dtparam=act_led_gpio=13

# HDMI audio capture
#dtoverlay=tc358743-audio

# SPI (AUM)
#dtoverlay=spi0-1cs

# I2C (display)
dtparam=i2c_arm=on

# Clock
dtoverlay=i2c-rtc,pcf8563
FIRMWARE

    else   # CSI platforms

      cat <<CSIFIRMWARE >> ${_BOOTCONF}
# srepac custom configs
###
hdmi_force_hotplug=1
gpu_mem=${GPUMEM}
enable_uart=1

dtoverlay=tc358743

dtoverlay=disable-bt
dtoverlay=dwc2,dr_mode=peripheral
dtparam=act_led_gpio=13

# HDMI audio capture
dtoverlay=tc358743-audio

# SPI (AUM)
dtoverlay=spi0-1cs

# I2C (display)
dtparam=i2c_arm=on

# Clock
dtoverlay=i2c-rtc,pcf8563
CSIFIRMWARE

      # add the tc358743 module to be loaded at boot for CSI
      if [[ $( grep -w tc358743 /etc/modules | wc -l ) -eq 0 ]]; then
        echo "tc358743" >> /etc/modules
      fi

      install-tc358743

    fi

  fi  # end of check if entries are already in /boot/config.txt

  # Remove OTG serial (Orange pi zero's kernel not support it)
  sed -i '/^g_serial/d' /etc/modules

  # /etc/modules required entries for DWC2, HID and I2C
  if [[ $( grep -w dwc2 /etc/modules | wc -l ) -eq 0 ]]; then
    echo "dwc2" >> /etc/modules
  fi
  if [[ $( grep -w libcomposite /etc/modules | wc -l ) -eq 0 ]]; then
    echo "libcomposite" >> /etc/modules
  fi
  if [[ $( grep -w i2c-dev /etc/modules | wc -l ) -eq 0 ]]; then
    echo "i2c-dev" >> /etc/modules
  fi

  if [ -e ${_BOOTCONF} ]; then
    printf "\n${_BOOTCONF}\n\n" | tee -a $LOGFILE
    cat ${_BOOTCONF} | tee -a $LOGFILE
  fi

  printf "\n/etc/modules\n\n" | tee -a $LOGFILE
  cat /etc/modules | tee -a $LOGFILE
} # end of necessary boot files

get-packages() {
  printf "\n\n-> Getting Pi-KVM packages from ${PIKVMREPO}\n\n" | tee -a $LOGFILE
  mkdir -p ${KVMDCACHE}/ARCHIVE
  if [ $( ls ${KVMDCACHE}/kvmd* > /dev/null 2>&1 | wc -l ) -gt 0 ]; then
    mv ${KVMDCACHE}/kvmd* ${KVMDCACHE}/ARCHIVE   ### move previous kvmd* packages into ARCHIVE
  fi

  echo "wget --no-check-certificate ${PIKVMREPO} -O ${PKGINFO}" | tee -a $LOGFILE
  wget --no-check-certificate ${PIKVMREPO} -O ${PKGINFO} 2> /dev/null
  echo

  # Download each of the pertinent packages for Rpi4, webterm, and the main service
  for pkg in `egrep 'janus|kvmd' ${PKGINFO} | grep -v sig | cut -d'>' -f1 | cut -d'"' -f2 | egrep -v 'fan|oled' | egrep 'janus|pi4|pi3|zero|webterm|kvmd-[0-9]'`
  do
    rm -f ${KVMDCACHE}/$pkg*
    echo "wget --no-check-certificate ${PIKVMREPO}/$pkg -O ${KVMDCACHE}/$pkg" | tee -a $LOGFILE
    wget --no-check-certificate ${PIKVMREPO}/$pkg -O ${KVMDCACHE}/$pkg 2> /dev/null
  done

  echo
  echo "ls -l ${KVMDCACHE}" | tee -a $LOGFILE
  ls -l ${KVMDCACHE} | tee -a $LOGFILE
  echo
} # end get-packages function

get-platform() {
  tryagain=1
  while [ $tryagain -eq 1 ]; do
    echo -n "Single Board Computer:  $MAKER " | tee -a $LOGFILE
    case $MAKER in
      Raspberry)       ### get which capture device for use with RPi boards
        model=$( tr -d '\0' < /proc/device-tree/model | cut -d' ' -f3,4,5 | sed -e 's/ //g' -e 's/Z/z/g' -e 's/Model//' -e 's/Rev//g'  -e 's/1.[0-9]//g' )

        echo "Pi Model $model" | tee -a $LOGFILE
        case $model in

          zero2*)
            # force platform to only use v2-hdmi for zero2w
            platform="kvmd-platform-v2-hdmi-zero2w"
            export GPUMEM=96
            tryagain=0
            ;;

          zero[Ww])
            ### added on 02/18/2022
            # force platform to only use v2-hdmi for zerow
            platform="kvmd-platform-v2-hdmi-zerow"
            ZEROWREPO="http://148.135.104.55/REPO/NEW"
            wget --no-check-certificate -O kvmnerds-packages.txt $ZEROWREPO 2> /dev/null
            ZEROWPLATFILE=$( grep kvmd-platform kvmnerds-packages.txt | grep -v sig | cut -d'"' -f4 | grep zerow | tail -1 | cut -d/ -f1 )

            # download the zerow platform file from custom repo
            echo "wget --no-check-certificate -O $KVMDCACHE/$ZEROWPLATFILE $ZEROWREPO/$ZEROWPLATFILE" | tee -a $LOGFILE
            wget --no-check-certificate -O $KVMDCACHE/$ZEROWPLATFILE $ZEROWREPO/$ZEROWPLATFILE 2> /dev/null
            export GPUMEM=64
            tryagain=0
            ;;

          3A*)
            ### added on 02/18/2022
            # force platform to only use v2-hdmi for rpi3 A+ ONLY
            # this script doesn't make distinction between rpi3 A, A+ or B
            ### it assumes you are using an rpi3 A+ that has the OTG support
            ### if your pikvm doesn't work (e.g. kb/mouse won't work), then
            ### ... rpi3 does NOT have an OTG port and will require arduino HID
            #platform="kvmd-platform-v2-hdmi-rpi3"    # this platform package doesn't support webrtc
            platform="kvmd-platform-v2-hdmi-rpi4"     # use rpi4 platform which supports webrtc
            export GPUMEM=96
            tryagain=0
            ;;

          "3B"|"2B"|"2A"|"B"|"A")
            ### added on 02/25/2022 but updated on 03/01/2022 (GPUMEM hardcoded to 16MB)
            echo "Pi ${model} board does not have OTG support.  You will need to use serial HID via Arduino."
            SERIAL=1   # set flag to indicate Serial HID (default is 0 for all other boards)
            number=$( echo $model | sed 's/[A-Z]//g' )

            tryagain=1
            while [ $tryagain -eq 1 ]; do
              printf "Choose which capture device you will use:\n\n
  1 - v0 USB dongle (ch9329 or arduino)
  2 - v0 CSI (ch9329 or arduino)
  3 - v1 USB dongle (pico hid)
  4 - v1 CSI (pico hid)

"
              read -p "Please type [1-4]: " capture
              case $capture in
                1) platform="kvmd-platform-v0-hdmiusb-rpi${number}"; tryagain=0;;
                2) platform="kvmd-platform-v0-hdmi-rpi${number}"; tryagain=0;;
                3) platform="kvmd-platform-v1-hdmiusb-rpi${number}"; tryagain=0;;
                4) platform="kvmd-platform-v1-hdmi-rpi${number}"; tryagain=0;;
                *) printf "\nTry again.\n"; tryagain=1;;
              esac
            done
            ;;

          "400")
            ### added on 02/22/2022 -- force pi400 to use usb dongle as there's no CSI connector on it
            platform="kvmd-platform-v2-hdmiusb-rpi4"
            export GPUMEM=256
            tryagain=0
            ;;

          *)   ### default to use rpi4 platform image for CM4 and Pi4
            tryagain=1
            while [ $tryagain -eq 1 ]; do
              printf "Choose which capture device you will use:\n
  1 - USB dongle
  2 - v2 CSI
  3 - V3 HAT
  4 - V4mini  (use this for any CM4 boards with CSI capture)
  5 - V4plus

"
              read -p "Please type [1-5]: " capture
              case $capture in
                1) platform="kvmd-platform-v2-hdmiusb-rpi4"; export GPUMEM=256; tryagain=0;;
                2) platform="kvmd-platform-v2-hdmi-rpi4"; export GPUMEM=128; csisvc=1; tryagain=0;;
                3) platform="kvmd-platform-v3-hdmi-rpi4"; export GPUMEM=128; csisvc=1; tryagain=0;;
                4) platform="kvmd-platform-v4mini-hdmi-rpi4"; export GPUMEM=128; csisvc=1; cm4=1; tryagain=0;;
                5) platform="kvmd-platform-v4plus-hdmi-rpi4"; export GPUMEM=128; csisvc=1; cm4=1; tryagain=0;;
                *) printf "\nTry again.\n"; tryagain=1;;
              esac
            done
            ;; # end case $model in *)

        esac # end case $model
        ;; # end case $MAKER in Raspberry)

      *) # other SBC makers can only support hdmi dongle
        model=$( tr -d '\0' < /proc/device-tree/model | cut -d' ' -f2,3,4,5,6 )
        echo "$model" | tee -a $LOGFILE
        platform="kvmd-platform-v2-hdmiusb-rpi4"; tryagain=0
        ;;

    esac # end case $MAKER

    echo
    echo "Platform selected -> $platform" | tee -a $LOGFILE
    echo
  done
} # end get-platform

install-kvmd-pkgs() {
  cd /

  INSTLOG="${KVMDCACHE}/installed_ver.txt"; rm -f $INSTLOG
  date > $INSTLOG

# uncompress platform package first
  i=$( ls ${KVMDCACHE}/${platform}*.tar.xz )  ### install the most up to date kvmd-platform package

  # change the log entry to show 3.291 platform installed as we'll be forcing kvmd-3.291 instead of latest/greatest kvmd
  _platformver=$( echo $i | sed -e 's/3\.29[2-9]*/3.291/g' -e 's/3\.3[0-9]*/3.291/g' -e 's/3.2911/3.291/g' -e 's/4\.[0-9].*-/3.291-/g' )
  echo "-> Extracting package $_platformver into /" | tee -a $INSTLOG
  tar xfJ $i

# then uncompress, kvmd-{version}, kvmd-webterm, and janus packages
  for i in $( ls ${KVMDCACHE}/*.tar.xz | egrep 'kvmd-[0-9]|webterm' )
  do
    case $i in
      *kvmd-3.29[2-9]*|*kvmd-3.[3-9]*|*kvmd-[45].[1-9]*)  # if latest/greatest is 3.292 and higher, then force 3.291 install
        echo "*** Force install kvmd 3.291 ***" | tee -a $LOGFILE
        # copy kvmd-3.291 package
        cp $CWD/$KVMDFILE $KVMDCACHE/
        i=$KVMDCACHE/$KVMDFILE
        ;;
      *)
        ;;
    esac

    echo "-> Extracting package $i into /" >> $INSTLOG
    tar xfJ $i
  done

  # uncompress janus package if /usr/bin/janus doesn't exist
  if [ ! -e /usr/bin/janus ]; then
    i=$( ls ${KVMDCACHE}/*.tar.xz | egrep janus | grep -v 1x )
    echo "-> Extracting package $i into /" >> $INSTLOG
    tar xfJ $i

  else      # confirm that /usr/bin/janus actually runs properly
    /usr/bin/janus --version > /dev/null 2>> $LOGFILE
    if [ $? -eq 0 ]; then
      echo "You have a working valid janus binary." | tee -a $LOGFILE
    else    # error status code, so uncompress from REPO package
      #i=$( ls ${KVMDCACHE}/*.tar.xz | egrep janus )
      #echo "-> Extracting package $i into /" >> $INSTLOG
      #tar xfJ $i
      apt-get remove janus janus-dev -y >> $LOGFILE
      apt-get install janus janus-dev -y >> $LOGFILE
    fi
  fi

  cd ${APP_PATH}
} # end install-kvmd-pkgs

fix-udevrules() {
  # for hdmiusb, replace %b with 1-1.4:1.0 in /etc/udev/rules.d/99-kvmd.rules
  sed -i -e 's+\%b+1-1.4:1.0+g' /etc/udev/rules.d/99-kvmd.rules | tee -a $LOGFILE
  echo
  cat /etc/udev/rules.d/99-kvmd.rules | tee -a $LOGFILE
} # end fix-udevrules

enable-kvmd-svcs() {
  # enable KVMD services but don't start them
  echo "-> Enabling $SERVICES services, but do not start them." | tee -a $LOGFILE
  systemctl enable $SERVICES

  case $( pikvm-info | grep kvmd-platform | cut -d'-' -f4 ) in
    hdmi)
      echo "Starting kvmd-tc358743 and kvmd-janus-static services for CSI 2 HDMI capture"
      systemctl restart kvmd-tc358743 kvmd-janus-static
      systemctl status kvmd-tc358743 kvmd-janus-static | grep Loaded
      ;;
    hdmiusb)
      echo "USB-HDMI capture"
      ;;
  esac | tee -a $LOGFILE
} # end enable-kvmd-svcs

build-ustreamer() {
  printf "\n\n-> Building ustreamer\n\n" | tee -a $LOGFILE
  # Install packages needed for building ustreamer source
  echo "apt install -y make libevent-dev libjpeg-dev libbsd-dev libgpiod-dev libsystemd-dev libmd-dev libdrm-dev janus-dev janus" | tee -a $LOGFILE
  apt install -y make libevent-dev libjpeg-dev libbsd-dev libgpiod-dev libsystemd-dev libmd-dev libdrm-dev janus-dev janus >> $LOGFILE

  # fix refcount.h
  sed -i -e 's|^#include "refcount.h"$|#include "../refcount.h"|g' /usr/include/janus/plugins/plugin.h

  # Download ustreamer source and build it
  cd /tmp
  git clone --depth=1 https://github.com/pikvm/ustreamer
  cd ustreamer/
  make WITH_GPIO=1 WITH_SYSTEMD=1 WITH_JANUS=1 WITH_V4P=1 -j
  make install
  # kvmd service is looking for /usr/bin/ustreamer
  ln -sf /usr/local/bin/ustreamer* /usr/bin/

  # add janus support
  mkdir -p /usr/lib/ustreamer/janus
  cp /tmp/ustreamer/janus/libjanus_ustreamer.so /usr/lib/ustreamer/janus
} # end build-ustreamer

install-dependencies() {
  echo
  echo "-> Installing dependencies for pikvm" | tee -a $LOGFILE

  echo "apt install -y nginx python3 net-tools bc expect v4l-utils iptables vim dos2unix screen tmate nfs-common gpiod ffmpeg dialog iptables dnsmasq git python3-pip tesseract-ocr tesseract-ocr-eng libasound2-dev libsndfile-dev libspeexdsp-dev libdrm-dev" | tee -a $LOGFILE
  apt install -y nginx python3 net-tools bc expect v4l-utils iptables vim dos2unix screen tmate nfs-common gpiod ffmpeg dialog iptables dnsmasq git python3-pip tesseract-ocr tesseract-ocr-eng libasound2-dev libsndfile-dev libspeexdsp-dev libdrm-dev >> $LOGFILE

  sed -i -e 's/#port=5353/port=5353/g' /etc/dnsmasq.conf

  install-python-packages

  echo "-> Install python3 modules dbus_next and zstandard" | tee -a $LOGFILE
  if [[ "$PYTHONVER" == "3.11" || "$PYTHONVER" == "3.12" ]]; then
    apt install -y python3-dbus-next python3-zstandard
  else
    pip3 install dbus_next zstandard
  fi

  echo "-> Make tesseract data link" | tee -a $LOGFILE
  ln -sf /usr/share/tesseract-ocr/*/tessdata /usr/share/tessdata

  echo "-> Install TTYD" | tee -a $LOGFILE
  apt install -y ttyd | tee -a $LOGFILE
  if [ ! -e /usr/bin/ttyd ]; then
    # Build and install ttyd
    cd /tmp
    apt-get install -y build-essential cmake git libjson-c-dev libwebsockets-dev
    git clone https://github.com/tsl0922/ttyd.git
    cd ttyd && mkdir build && cd build
    cmake ..
    make -j && make install
    cp ttyd /usr/bin/ttyd
    # Install binary from GitHub
    #arch=$(dpkg --print-architecture)
    #latest=$(curl -sL https://api.github.com/repos/tsl0922/ttyd/releases/latest | jq -r ".tag_name")
    #latest=1.6.3     # confirmed works with pikvm, latest from github (1.7.4) did not allow typing in webterm
    #if [ $arch = arm64 ]; then
    #  arch='aarch64'
    #fi
    #wget --no-check-certificate "https://github.com/tsl0922/ttyd/releases/download/$latest/ttyd.$arch" -O /usr/bin/ttyd
    chmod +x /usr/bin/ttyd
  fi
  /usr/bin/ttyd -v | tee -a $LOGFILE

  if [ ! -e /usr/local/bin/gpio ]; then
    printf "\n\n-> Building wiringpi from source\n\n" | tee -a $LOGFILE
    cd /tmp; rm -rf WiringPi
    git clone https://github.com/WiringPi/WiringPi.git
    cd WiringPi
    ./build
  else
    printf "\n\n-> Wiringpi (gpio) is already installed.\n\n" | tee -a $LOGFILE
  fi
  gpio -v | tee -a $LOGFILE

  echo "-> Install ustreamer" | tee -a $LOGFILE
  if [ ! -e /usr/bin/ustreamer ]; then
    cd /tmp
    apt-get install -y libevent-2.1-7 libevent-core-2.1-7 libevent-pthreads-2.1-7 build-essential
    ### required dependent packages for ustreamer ###
    build-ustreamer
    cd ${APP_PATH}
  fi
  echo -n "ustreamer version: " | tee -a $LOGFILE
  ustreamer -v | tee -a $LOGFILE
  ustreamer --features | tee -a $LOGFILE
} # end install-dependencies

python-pkg-dir() {
  # debian system python3 no alias
  # create quick python script to show where python packages need to go
  cat << MYSCRIPT > /tmp/syspath.py
#!$(which python3)
import sys
print (sys.path)
MYSCRIPT

  chmod +x /tmp/syspath.py

  #PYTHONDIR=$( /tmp/syspath.py | awk -F, '{print $NF}' | cut -d"'" -f2 )
  ### hardcode path for armbian/raspbian
  PYTHONDIR="/usr/lib/python3/dist-packages"
} # end python-pkg-dir

fix-nginx-symlinks() {
  # disable default nginx service since we will use kvmd-nginx instead
  echo
  echo "-> Disabling nginx service, so that we can use kvmd-nginx instead" | tee -a $LOGFILE
  systemctl disable --now nginx

  # setup symlinks
  echo
  echo "-> Creating symlinks for use with kvmd python scripts" | tee -a $LOGFILE
  if [ ! -e /usr/bin/nginx ]; then ln -sf /usr/sbin/nginx /usr/bin/; fi
  if [ ! -e /usr/sbin/python ]; then ln -sf /usr/bin/python3 /usr/sbin/python; fi
  if [ ! -e /usr/bin/iptables ]; then ln -sf /usr/sbin/iptables /usr/bin/iptables; fi
  if [ ! -e /usr/bin/vcgencmd ]; then ln -sf /opt/vc/bin/* /usr/bin/; fi

  python-pkg-dir

  if [ ! -e $PYTHONDIR/kvmd ]; then
    # Debian python版本比 pikvm官方的低一些
    # in case new kvmd packages are now using python 3.11
    ln -sf /usr/lib/python3.1*/site-packages/kvmd* ${PYTHONDIR}
  fi
} # end fix-nginx-symlinks

fix-python-symlinks(){
  python-pkg-dir

  if [ ! -e $PYTHONDIR/kvmd ]; then
    # Debian python版本比 pikvm官方的低一些
    ln -sf /usr/lib/python3.1*/site-packages/kvmd* ${PYTHONDIR}
  fi
}

apply-custom-patch(){
  read -p "Do you want apply old kernel msd patch? [y/n]" answer
  case $answer in
    n|N|no|No)
      echo 'You skipped this patch.'
      ;;
    y|Y|Yes|yes)
      ./patches/custom/old-kernel-msd/apply.sh
      ;;
    *)
      echo "Try again.";;
  esac
}

fix-kvmd-for-tvbox-armbian(){
  # 打补丁来移除一些对armbian和电视盒子不太支持的特性
  cd /usr/lib/python3.10/site-packages/
  git apply ${APP_PATH}/patches/bullseye/*.patch
  cd ${APP_PATH}
  read -p "Do you want to apply custom patches?  [y/n] " answer
  case $answer in
    n|N|no|No)
     return;
     ;;
    y|Y|Yes|yes)
     apply-custom-patch;
     return;
     ;;
    *)
     echo "Try again.";;
  esac
}

fix-webterm() {
  echo
  echo "-> Creating kvmd-webterm homedir" | tee -a $LOGFILE
  mkdir -p /home/kvmd-webterm
  chown kvmd-webterm /home/kvmd-webterm
  ls -ld /home/kvmd-webterm | tee -a $LOGFILE

  # remove -W option since ttyd installed on raspbian/armbian is 1.6.3 (-W option only works with ttyd 1.7.x)
  _ttydver=$( /usr/bin/ttyd -v | awk '{print $NF}' )
  case $_ttydver in
    1.6*)
      echo "ttyd $_ttydver found.  Removing -W from /lib/systemd/system/kvmd-webterm.service"
      sed -i -e '/-W \\/d' /lib/systemd/system/kvmd-webterm.service
      ;;
    1.7*)
      echo "ttyd $_ttydver found.  Nothing to do."
      ;;
  esac

  # add sudoers entry for kvmd-webterm user to be able to run sudo
  echo "kvmd-webterm ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/kvmd-webterm; chmod 440 /etc/sudoers.d/kvmd-webterm
} # end fix-webterm

create-kvmdfix() {
  # Create kvmd-fix service and script
  cat <<ENDSERVICE > /lib/systemd/system/kvmd-fix.service
[Unit]
Description=KVMD Fixes
After=network.target network-online.target nss-lookup.target
Before=kvmd.service

[Service]
User=root
Type=simple
ExecStart=/usr/bin/kvmd-fix

[Install]
WantedBy=multi-user.target
ENDSERVICE

  cat <<SCRIPTEND > /usr/bin/kvmd-fix
#!/bin/bash
# Written by @srepac
# 1.  Properly set group ownership of /dev/gpio*
# 2.  fix /dev/kvmd-video symlink to point to /dev/video1 (Amglogic Device video0 is not usb device)
#
### These fixes are required in order for kvmd service to start properly
#
set -x
chgrp gpio /dev/gpio*
chmod 660 /dev/gpio*
ls -l /dev/gpio*

udevadm trigger
ls -l /dev/kvmd-video

if [ \$( systemctl | grep kvmd-oled | grep -c activ ) -eq 0 ]; then
  echo "kvmd-oled service is not enabled."
  exit 0
else
  echo "kvmd-oled service is enabled and activated."
fi

### kvmd-oled fix: swap i2c-0 <-> i2c-1  (code is looking for I2C oled on i2c-1)
# pins #1 - 3.3v, #3 - SDA, #5 - SCL, and #9 - GND
i2cget -y 0 0x3c
if [ \$? -eq 0 ]; then
  echo "-> Found valid I2C OLED at i2c-0.  Applying I2C OLED fix."
  cd /dev

  # rename i2c-0 -> i2c-9, move i2c-1 to i2c-0, and rename the good i2c-9 to i2c-1
  mv i2c-0 i2c-9
  mv i2c-1 i2c-0
  mv i2c-9 i2c-1

  # restart kvmd-oled service
  systemctl restart kvmd-oled
else
  echo "-> I2C OLED fix already applied and OLED should be showing info."
fi
SCRIPTEND

  chmod +x /usr/bin/kvmd-fix
} # end create-kvmdfix

set-ownership() {
  # set proper ownership of password files and kvmd-webterm homedir
  cd /etc/kvmd
  chown kvmd:kvmd htpasswd
  chown kvmd-ipmi:kvmd-ipmi ipmipasswd
  chown kvmd-vnc:kvmd-vnc vncpasswd
  chown kvmd-webterm /home/kvmd-webterm

  # add kvmd user to video group (this is required in order to use CSI bridge with OMX and h264 support)
  usermod -a -G video kvmd

  # add kvmd user to dialout group (required for xh_hk4401 kvm switch support)
  usermod -a -G dialout kvmd
} # end set-ownership

check-kvmd-works() {
  echo "-> Checking kvmd -m works before continuing" | tee -a $LOGFILE
  invalid=1
  while [ $invalid -eq 1 ]; do
    kvmd -m | tee -a $LOGFILE
    read -p "Did kvmd -m run properly?  [y/n] " answer
    case $answer in
      n|N|no|No)
        echo "Please install missing packages as per the kvmd -m output in another ssh/terminal."
        ;;
      y|Y|Yes|yes)
        invalid=0
        ;;
      *)
        echo "Try again.";;
    esac
  done
} # end check-kvmd-works

start-kvmd-svcs() {
  #### start the main KVM services in order ####
  # 1. nginx is the webserver
  # 2. kvmd-otg is for OTG devices (keyboard/mouse, etc..)
  # 3. kvmd is the main daemon
  systemctl daemon-reload
  systemctl restart $SERVICES
} # end start-kvmd-svcs

fix-motd() {
  if [ -e /etc/motd ]; then rm /etc/motd; fi
  cp armbian/armbian-motd /usr/bin/
  sed -i 's/cat \/etc\/motd/armbian-motd/g' /lib/systemd/system/kvmd-webterm.service
  systemctl daemon-reload
  # systemctl restart kvmd-webterm
} # end fix-motd

# 安装armbian的包
armbian-packages() {
  mkdir -p /opt/vc/bin/
  #cd /opt/vc/bin
  if [ ! -e /usr/bin/vcgencmd ]; then
    # Install vcgencmd for armbian platform
    cp -rf armbian/opt/* /opt/vc/bin
  else
    ln -s /usr/bin/vcgencmd /opt/vc/bin/
  fi
  #cp -rf armbian/udev /etc/

  cd ${APP_PATH}
} # end armbian-packages

fix-nfs-msd() {
  NAME="aiofiles.tar"

  for i in 3.11 3.12; do
    LOCATION="/usr/lib/python$i/site-packages"
    if [ -e $LOCATION ]; then
      echo "-> Extracting $NAME into $LOCATION" | tee -a $LOGFILE
      tar xvf $NAME -C $LOCATION

      echo "-> Renaming original aiofiles and creating symlink to correct aiofiles" | tee -a $LOGFILE
      cd /usr/lib/python3/dist-packages
      mv aiofiles aiofiles.$(date +%Y%m%d.%H%M)
      ln -s $LOCATION/aiofiles .
      ls -ld aiofiles* | tail -5
    fi
  done
}

fix-nginx() {
  #set -x
  KERNEL=$( uname -r | awk -F\- '{print $1}' )
  ARCH=$( uname -r | awk -F\- '{print $NF}' )
  echo "KERNEL:  $KERNEL   ARCH:  $ARCH" | tee -a $LOGFILE
  case $ARCH in
    ARCH) SEARCHKEY=nginx-mainline;;
    *) SEARCHKEY="nginx/";;
  esac

  HTTPSCONF="/etc/kvmd/nginx/listen-https.conf"
  echo "HTTPSCONF BEFORE:  $HTTPSCONF" | tee -a $LOGFILE
  cat $HTTPSCONF | tee -a $LOGFILE

  if [[ ! -e /usr/local/bin/pikvm-info || ! -e /tmp/pacmanquery ]]; then
    wget --no-check-certificate -O /usr/local/bin/pikvm-info http://148.135.104.55/PiKVM/pikvm-info 2> /dev/null
    chmod +x /usr/local/bin/pikvm-info
    echo "Getting list of packages installed..." | tee -a $LOGFILE
    pikvm-info > /dev/null    ### this generates /tmp/pacmanquery with list of installed pkgs
  fi

  NGINXVER=$( grep $SEARCHKEY /tmp/pacmanquery | awk '{print $1}' | cut -d'.' -f1,2 )
  echo
  echo "NGINX version installed:  $NGINXVER" | tee -a $LOGFILE

  case $NGINXVER in
    1.2[56789]|1.3*|1.4*|1.5*)   # nginx version 1.25 and higher
      cat << NEW_CONF > $HTTPSCONF
listen 443 ssl;
listen [::]:443 ssl;
http2 on;
NEW_CONF
      ;;

    1.18|*)   # nginx version 1.18 and lower
      cat << ORIG_CONF > $HTTPSCONF
listen 443 ssl http2;
listen [::]:443 ssl;
ORIG_CONF
      ;;

  esac

  echo "HTTPSCONF AFTER:  $HTTPSCONF" | tee -a $LOGFILE
  cat $HTTPSCONF | tee -a $LOGFILE
  set +x
} # end fix-nginx

ocr-fix() {  # create function
  echo
  echo "-> Apply OCR fix..." | tee -a $LOGFILE

  set -x
  # 1.  verify that Pillow module is currently running 9.0.x
  PILLOWVER=$( grep -i pillow $PIP3LIST | awk '{print $NF}' )

  case $PILLOWVER in
    9.*|8.*|7.*)   # Pillow running at 9.x and lower
      # 2.  update Pillow to 10.0.0
      pip3 install -U Pillow 2>> $LOGFILE

      # 3.  check that Pillow module is now running 10.0.0
      pip3 list | grep -i pillow | tee -a $LOGFILE

      #4.  restart kvmd and confirm OCR now works.
      systemctl restart kvmd
      ;;

    10.*|11.*|12.*)  # Pillow running at 10.x and higher
      echo "Already running Pillow $PILLOWVER.  Nothing to do." | tee -a $LOGFILE
      ;;

  esac

  set +x
  echo
} # end ocr-fix

async-lru-fix() {
  echo
  echo "-> Ensuring async-lru is installed with version 2.x ..." | tee -a $LOGFILE
  pip3 install async-lru 2> /dev/null
  PIP3LIST="/tmp/pip3.list"; /bin/rm -f $PIP3LIST
  pip3 list 2> /dev/null > $PIP3LIST

  ASYNCLRUVER=$( grep -i 'async[-_]lru' $PIP3LIST | awk '{print $NF}' )
  echo "ASYNC-LRU version:  $ASYNCLRUVER"
  case $ASYNCLRUVER in
    2.*) echo "Nothing to do.  aync-lru is already running $ASYNCLRUVER" | tee -a $LOFILE;;
    1.*|*) pip3 install -U async_lru --break-system-packages | tee -a $LOGFILE;;     # raspbian bookworm only installs 1.0.x, this forces 2.0.x
  esac
} # end async-lru-fix

cm4-mods() {  # apply CM4 specific mods
  if [ $cm4 -eq 1 ]; then
    echo "-> Applying CM4 specific changes" | tee -a $LOGFILE

    # Add CM4 otg fix
    sed -i --follow-symlinks -e 's/^otg_mode=1/#otg_mode=1/g' ${_BOOTCONF}

    # add 4lane CSI support
    sed -i --follow-symlinks -e 's|^dtoverlay=tc358743$|\n# Video (CM4)\ndtoverlay=tc358743,4lane=1\n|g' ${_BOOTCONF}

    # v4mini and v4plus yaml file are the same
    cp /etc/kvmd/main.yaml /etc/kvmd/main.yaml.orig
    cp /usr/share/kvmd/configs.default/kvmd/main/v4mini-hdmi-rpi4.yaml /etc/kvmd/main.yaml

    # update EDID to support 1920x1080p 60hz and 1920x1200 60hz
    cp /etc/kvmd/tc358743-edid.hex /etc/kvmd/tc358743-edid.hex.orig
    cp /usr/share/kvmd/configs.default/kvmd/edid/v4mini-hdmi.hex /etc/kvmd/tc358743-edid.hex
  fi
} # end cm4-mods

update-logo() {
  sed -i -e 's|class="svg-gray"|class="svg-color"|g' /usr/share/kvmd/web/index.html
  sed -i -e 's|target="_blank"><img class="svg-gray"|target="_blank"><img class="svg-color"|g' /usr/share/kvmd/web/kvm/index.html

  ### download opikvm-logo.svg and then overwrite logo.svg
  wget --no-check-certificate -O /usr/share/kvmd/web/share/svg/opikvm-logo.svg https://github.com/srepac/kvmd-armbian/raw/master/opikvm-logo.svg > /dev/null 2> /dev/null
  cd /usr/share/kvmd/web/share/svg
  cp logo.svg logo.svg.old
  cp opikvm-logo.svg logo.svg

  # change some text in the main html page
  sed -i.bak -e 's/The Open Source KVM over IP/KVM over IP on non-Arch linux OS by @srepac/g' /usr/share/kvmd/web/index.html
  sed -i.bak -e 's/The Open Source KVM over IP/KVM over IP on non-Arch linux OS by @srepac/g' /usr/share/kvmd/web/kvm/index.html
  sed -i.backup -e 's|https://pikvm.org/support|https://discord.gg/YaJ87sVznc|g' /usr/share/kvmd/web/kvm/index.html
  sed -i.backup -e 's|https://pikvm.org/support|https://discord.gg/YaJ87sVznc|g' /usr/share/kvmd/web/index.html
  cd
}

function fix-hk4401() {
  # https://github.com/ThomasVon2021/blikvm/issues/168

  # Download kvmd-4.2 package from kvmnerds.com to /tmp and extract only the xh_hk4401.py script
  cd /tmp
  wget --no-check-certificate -O kvmd-4.2-1-any.pkg.tar.xz http://148.135.104.55/REPO/NEW/kvmd-4.2-1-any.pkg.tar.xz 2> /dev/null
  tar xvfJ kvmd-4.2-1-any.pkg.tar.xz --wildcards --no-anchored 'xh_hk4401.py'

  # Show diff of 4.2 version of xh_hk4401.py vs. current installed version
  cd usr/lib/python3.12/site-packages/kvmd/plugins/ugpio/
  diff xh_hk4401.py /usr/lib/python3/dist-packages/kvmd/plugins/ugpio/

  # make a backup of current xh_hk4401.py script
  cp /usr/lib/python3/dist-packages/kvmd/plugins/ugpio/xh_hk4401.py /usr/lib/python3/dist-packages/kvmd/plugins/ugpio/xh_hk4401.py.3.291

  # replace it with the kvmd 4.2 version of script which allows use of protocol: 2
  cp xh_hk4401.py /usr/lib/python3/dist-packages/kvmd/plugins/ugpio/
  cd
} # end fix-hk4401


### MAIN STARTS HERE ###
# Install is done in two parts
# First part requires a reboot in order to create kvmd users and groups
# Second part will start the necessary kvmd services

# if /etc/kvmd/htpasswd exists, then make a backup
if [ -e /etc/kvmd/htpasswd ]; then cp /etc/kvmd/htpasswd /etc/kvmd/htpasswd.save; fi

### I uploaded all these into github on 05/22/23 -- so just copy them into correct location
cd ${APP_PATH}
cp -rf pistat /usr/local/bin/pistat
cp -rf pi-temp /usr/local/bin/pi-temp
cp -rf pikvm-info /usr/local/bin/pikvm-info
cp -rf update-rpikvm.sh /usr/local/bin/update-rpikvm.sh
chmod +x /usr/local/bin/pi* /usr/local/bin/update-rpikvm.sh

### fix for kvmd 3.230 and higher
ln -sf python3 /usr/bin/python

SERVICES="kvmd-nginx kvmd-webterm kvmd-otg kvmd kvmd-fix"

# added option to re-install by adding -f parameter (for use as platform switcher)
PYTHON_VERSION=$( python3 -V | awk '{print $2}' | cut -d'.' -f1,2 )
if [[ $( grep kvmd /etc/passwd | wc -l ) -eq 0 || "$1" == "-f" ]]; then
  printf "\nRunning part 1 of PiKVM installer script v$VER by @srepac\n" | tee -a $LOGFILE
  get-platform
  get-packages
  install-kvmd-pkgs
  enable-csi-svcs
  cm4-mods
  boot-files
  create-override
  gen-ssl-certs
  fix-udevrules
  install-dependencies
  otg-devices
  armbian-packages
  systemctl disable --now janus ttyd

  printf "\nEnd part 1 of PiKVM installer script v$VER by @srepac\n" >> $LOGFILE
  printf "\nReboot is required to create kvmd users and groups.\nPlease re-run this script after reboot to complete the install.\n" | tee -a $LOGFILE

  # Fix paste-as-keys if running python 3.7
  if [[ $( python3 -V | awk '{print $2}' | cut -d'.' -f1,2 ) == "3.7" ]]; then
    sed -i -e 's/reversed//g' /usr/lib/python3.1*/site-packages/kvmd/keyboard/printer.py
  fi

  ### run these to make sure kvmd users are created ###
  echo "-> Ensuring KVMD users and groups ..." | tee -a $LOGFILE
  systemd-sysusers /usr/lib/sysusers.d/kvmd.conf
  systemd-sysusers /usr/lib/sysusers.d/kvmd-webterm.conf

  # Ask user to press CTRL+C before reboot or ENTER to proceed with reboot
  press-enter
  reboot
else
  printf "\nRunning part 2 of PiKVM installer script v$VER by @srepac\n" | tee -a $LOGFILE

  echo "-> Re-installing janus ..." | tee -a $LOGFILE
  apt reinstall -y janus > /dev/null 2>&1

  ### run these to make sure kvmd users are created ###
  echo "-> Ensuring KVMD users and groups ..." | tee -a $LOGFILE
  systemd-sysusers /usr/lib/sysusers.d/kvmd.conf
  systemd-sysusers /usr/lib/sysusers.d/kvmd-webterm.conf

  fix-nginx-symlinks
  fix-python-symlinks
  fix-webterm
  fix-motd
  fix-nfs-msd
  fix-nginx
  async-lru-fix
  ocr-fix
  fix-hk4401
  
  set-ownership
  create-kvmdfix

  ### additional python pip dependencies for kvmd 3.238 and higher
  case $PYTHONVER in
    3.10*|3.[987]*)
      pip3 install async-lru 2> /dev/null
      ### Fix for kvmd 3.291 -- only applies to python 3.10 ###
      sed -i -e 's|gpiod.EdgeEvent|gpiod.LineEvent|g' /usr/lib/python3/dist-packages/kvmd/aiogp.py
      sed -i -e 's|gpiod.line,|gpiod.Line,|g'         /usr/lib/python3/dist-packages/kvmd/aiogp.py
      ;;
    3.1[1-9]*)
      pip3 install async-lru --break-system-packages 2> /dev/null
      ;;
  esac
  check-kvmd-works

  enable-kvmd-svcs
  update-logo
  start-kvmd-svcs

  printf "\nCheck kvmd devices\n\n" | tee -a $LOGFILE
  ls -l /dev/kvmd* | tee -a $LOGFILE
  printf "\nYou should see devices for keyboard, mouse, and video.\n" | tee -a $LOGFILE

  printf "\nPoint a browser to https://$(hostname)\nIf it doesn't work, then reboot one last time.\nPlease make sure kvmd services are running after reboot.\n" | tee -a $LOGFILE
fi

cd $CWD
cp -rf web.css /etc/kvmd/web.css

systemctl status $SERVICES | grep Loaded | tee -a $LOGFILE

### fix totp.secret file permissions for use with 2FA
chmod go+r /etc/kvmd/totp.secret
chown kvmd:kvmd /etc/kvmd/totp.secret

### create rw and ro so that /usr/bin/kvmd-bootconfig doesn't fail
touch /usr/local/bin/rw /usr/local/bin/ro
chmod +x /usr/local/bin/rw /usr/local/bin/ro

### update default hostname info in webui to reflect current hostname
sed -i -e "s/localhost.localdomain/`hostname`/g" /etc/kvmd/meta.yaml

### restore htpasswd from previous install, if applies
if [ -e /etc/kvmd/htpasswd.save ]; then cp /etc/kvmd/htpasswd.save /etc/kvmd/htpasswd; fi

### instead of showing # fps dynamic, show REDACTED fps dynamic instead;  USELESS fps meter fix
#sed -i -e 's|${__fps}|REDACTED|g' /usr/share/kvmd/web/share/js/kvm/stream_mjpeg.js

### fix kvmd-webterm 0.49 change that changed ttyd to kvmd-ttyd which broke webterm
sed -i -e 's/kvmd-ttyd/ttyd/g' /lib/systemd/system/kvmd-webterm.service

# get rid of this line, otherwise kvmd-nginx won't start properly since the nginx version is not 1.25 and higher
if [ -e /etc/kvmd/nginx/nginx.conf.mako ]; then
  sed -i -e '/http2 on;/d' /etc/kvmd/nginx/nginx.conf.mako
fi

systemctl restart kvmd-nginx kvmd-webterm kvmd
