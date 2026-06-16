#!/bin/bash
# https://github.com/srepac/kvmd-armbian
#
# modified by xe5700            2021-11-04      xe5700@outlook.com
# modified by NewbieOrange      2021-11-04
# created by @srepac   08/09/2021   srepac@kvmnerds.com
# Scripted Installer of Pi-KVM on x86 (as long as it's running python 3.10 or higher)
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
CWD=`pwd`

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  echo "usage:  $0 [-f]   where -f will force re-install new pikvm platform"
  exit 1
fi

WHOAMI=$( whoami )
if [ "$WHOAMI" != "root" ]; then
  echo "$WHOAMI, please run script as root."
  exit 1
fi

PYTHONVER=$( python3 -V | cut -d' ' -f2 | cut -d'.' -f1,2 )
case $PYTHONVER in
  3.1[0-9])   # supports python 3.10+
    echo "Python $PYTHONVER is supported." | tee -a $LOGFILE
    ;;
  *)
    echo "Python $PYTHONVER is NOT supported.  Please make sure you have python3.10 or higher installed.  Exiting." | tee -a $LOGFILE
    exit 1
    ;;
esac

### added on 01/31/23 in case armbian is installed on rpi boards
if [[ ! -e /boot/config.txt && -e /boot/firmware/config.txt ]]; then
  ln -sf /boot/firmware/config.txt /boot/config.txt
fi

MAKER="x86-pikvm"

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

create-override() {
  if [ $( grep ^kvmd: /etc/kvmd/override.yaml | wc -l ) -eq 0 ]; then

    if [[ $( echo $platform | grep usb | wc -l ) -eq 1 ]]; then
      cat <<USBOVERRIDE >> /etc/kvmd/override.yaml
kvmd:
    hid:
        ### add entries for use with the ch9329 serial HID
        type: ch9329
        speed: 9600     # default speed after loading ch9329 plugin is 9600
        device: /dev/kvmd-hid
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
    hid:
        ### add entries for use with the ch9329 serial HID
        type: ch9329
        speed: 9600     # default speed after loading ch9329 plugin is 9600
        device: /dev/kvmd-hid
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
setproctitle setuptools six spidev systemd tabulate urllib3 wrapt xlib yaml yarl pyotp qrcode serial serial-asyncio" )
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
  curl https://www.linux-projects.org/listing/uv4l_repo/lpkey.asc | apt-key add -
  echo "deb https://www.linux-projects.org/listing/uv4l_repo/raspbian/stretch stretch main" | tee /etc/apt/sources.list.d/uv4l.list

  #apt-get update > /dev/null
  echo "apt-get install uv4l-tc358743-extras -y"
  apt-get install uv4l-tc358743-extras -y > /dev/null
} # install package for tc358743

boot-files() {
  if [[ -e /boot/config.txt && $( grep srepac /boot/config.txt | wc -l ) -eq 0 ]]; then

    if [[ $( echo $platform | grep usb | wc -l ) -eq 1 ]]; then  # hdmiusb platforms

      cat <<FIRMWARE >> /boot/config.txt
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

      cat <<CSIFIRMWARE >> /boot/config.txt
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

    fi

  fi  # end of check if entries are already in /boot/config.txt

  #install-tc358743

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

  if [ -e /boot/config.txt ]; then
    printf "\n/boot/config.txt\n\n" | tee -a $LOGFILE
    cat /boot/config.txt | tee -a $LOGFILE
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

  # only get the latest kvmd version
  LATESTKVMD=$( grep kvmd-[0-9] $PKGINFO | grep -v sig | tail -1 )
  VERSION=$( echo $LATESTKVMD | cut -d'-' -f2 )

  # Download each of the pertinent packages for Rpi4, webterm, and the main service
  for pkg in `egrep "janus|$LATESTKVMD|$platform-$VERSION|webterm" ${PKGINFO} | grep -v sig | cut -d'>' -f1 | cut -d'"' -f2`
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
    case $MAKER in
      Raspberry)       ### get which capture device for use with RPi boards
        # amglogic tv box only has usb port, use usb dongle.
        printf "Choose which capture device you will use:\n\n  1 - USB dongle\n  2 - v2 CSI\n  3 - V3 HAT\n"
        read -p "Please type [1-3]: " capture
        ;;

      *) capture=1;;    ### force all other sbcs to use hdmiusb platform
    esac

    case $capture in
      1) platform="kvmd-platform-v0-hdmiusb-rpi3"; tryagain=0;;    ## force x86 install to use rpi3 + serial hid
      2) platform="kvmd-platform-v2-hdmi-rpi4"; tryagain=0;;
      3) platform="kvmd-platform-v3-hdmi-rpi4"; tryagain=0;;
      *) printf "\nTry again.\n"; tryagain=1;;
    esac

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
  i=$( ls ${KVMDCACHE}/${platform}*.tar.xz )
  _platformver=$( echo $i | sed -e 's/3\.29[2-9]*/3.291/g' -e 's/3\.3[0-9]*/3.291/g' )
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

    echo "-> Extracting package $i into /" | tee -a $INSTLOG
    tar xfJ $i
  done

  # uncompress janus package if /usr/bin/janus doesn't exist
  if [ ! -e /usr/bin/janus ]; then
    i=$( ls ${KVMDCACHE}/*.tar.xz | egrep janus | grep -v 1x )
    echo "-> Extracting package $i into /" | tee -a $INSTLOG
    tar xfJ $i

  else      # confirm that /usr/bin/janus actually runs properly
    /usr/bin/janus --version > /dev/null 2> /dev/null
    if [ $? -eq 0 ]; then
      echo "You have a working valid janus binary." | tee -a $LOGFILE
    else    # error status code, so uncompress from REPO package
      i=$( ls ${KVMDCACHE}/*.tar.xz | egrep janus )
      echo "-> Extracting package $i into /" | tee -a $INSTLOG
      tar xfJ $i
    fi
  fi

  cd ${APP_PATH}
} # end install-kvmd-pkgs

fix-udevrules() {
  # for hdmiusb, replace %b with 1-1.4:1.0 in /etc/udev/rules.d/99-kvmd.rules
  sed -i -e 's+\%b+1-1.4:1.0+g' -e 's+ttyAMA0+ttyUSB[0-2]+g' /etc/udev/rules.d/99-kvmd.rules | tee -a $LOGFILE
  echo
  cat /etc/udev/rules.d/99-kvmd.rules | tee -a $LOGFILE
} # end fix-udevrules

enable-kvmd-svcs() {
  # enable KVMD services but don't start them
  echo "-> Enabling $SERVICES services, but do not start them." | tee -a $LOGFILE
  systemctl enable $SERVICES
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
} # end build-ustreamer

install-dependencies() {
  echo
  echo "-> Installing dependencies for pikvm" | tee -a $LOGFILE

  echo "apt install -y nginx python3 net-tools bc expect v4l-utils iptables vim dos2unix screen tmate nfs-common gpiod ffmpeg dialog iptables dnsmasq git python3-pip tesseract-ocr tesseract-ocr-eng libasound2-dev libsndfile-dev libspeexdsp-dev lm-sensors libdrm-dev" | tee -a $LOGFILE
  apt install -y nginx python3 net-tools bc expect v4l-utils iptables vim dos2unix screen tmate nfs-common gpiod ffmpeg dialog iptables dnsmasq git python3-pip tesseract-ocr tesseract-ocr-eng libasound2-dev libsndfile-dev libspeexdsp-dev lm-sensors libdrm-dev >> $LOGFILE

  sed -i -e 's/#port=5353/port=5353/g' /etc/dnsmasq.conf

  install-python-packages

  echo "-> Install python3 modules dbus_next and zstandard" | tee -a $LOGFILE
  if [[ "$PYTHONVER" == "3.11" ]]; then
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
    # cd /tmp
    apt-get install -y build-essential cmake git libjson-c-dev libwebsockets-dev
    git clone https://github.com/tsl0922/ttyd.git
    cd ttyd && mkdir build && cd build
    cmake ..
    make -j && make install
    cp ttyd /usr/bin/ttyd
    # Install binary from GitHub
    #arch=$(dpkg --print-architecture)
    #latest=$(curl -sL https://api.github.com/repos/tsl0922/ttyd/releases/latest | jq -r ".tag_name")
    #if [ $arch = arm64 ]; then
    #  arch='aarch64'
    #fi
    #wget --no-check-certificate "https://github.com/tsl0922/ttyd/releases/download/$latest/ttyd.$arch" -O /usr/bin/ttyd
    chmod +x /usr/bin/ttyd
  fi

  printf "\n\n-> Building wiringpi from source\n\n" | tee -a $LOGFILE
  cd /tmp; rm -rf WiringPi
  git clone https://github.com/WiringPi/WiringPi.git
  cd WiringPi
  ./build
  gpio -v

  echo "-> Install ustreamer" | tee -a $LOGFILE
  if [ ! -e /usr/bin/ustreamer ]; then
    cd /tmp
    apt-get install -y libevent-2.1-7 libevent-core-2.1-7 libevent-pthreads-2.1-7 build-essential
    ### required dependent packages for ustreamer ###
    build-ustreamer
    cd ${APP_PATH}
  fi
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
  _ttydver=$( ttyd -v | awk '{print $NF}' )
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

# create this dir so that running kvmd-otgconf doesn't give errors
mkdir -p /run/kvmd/otg
/root/ch_reset.py

if [ \$( ls /dev/ | grep -c gpio ) -gt 0 ]; then
  chgrp gpio /dev/gpio*
  chmod 660 /dev/gpio*
  ls -l /dev/gpio*
fi

udevadm trigger
sleep 3
ls -l /dev/kvmd*

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

  cat << CHRESET > /root/ch_reset.py
#!/usr/bin/python3
import serial
import time

device_path = "/dev/kvmd-hid"

chip = serial.Serial(device_path, 9600, timeout=1)

command = [87, 171, 0, 15, 0]
sum = sum(command) % 256
command.append(sum)

print("Resetting CH9329")

chip.write(serial.to_bytes(command))

time.sleep(2)

data = list(chip.read(5))

print("Initial data:", data)

if data[4] :
        more_data = list(chip.read(data[4]))
        data.extend(more_data)

print("Output: ", data)


chip.close()
CHRESET

  chmod +x /root/ch_reset.py
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
    kvmd -m
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
  sed -i -e 's/Orange Pi/x86 PC/g' -e 's|^/etc|#/etc|g' /usr/bin/armbian-motd
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

  LOCATION="/usr/lib/python3.11/site-packages"
  echo "-> Extracting $NAME into $LOCATION" | tee -a $LOGFILE
  tar xvf $NAME -C $LOCATION

  echo "-> Renaming original aiofiles and creating symlink to correct aiofiles" | tee -a $LOGFILE
  cd /usr/lib/python3/dist-packages
  mv aiofiles aiofiles.$(date +%Y%m%d.%H%M)
  ln -s $LOCATION/aiofiles .
  ls -ld aiofiles* | tail -5 | tee -a $LOGFILE
}

add-ch9329-support() {
  wget --no-check-certificate -O install-ch9329.sh https://192.236.131.217/PiKVM/install-ch9329.sh 2> /dev/null
  chmod +x install-ch9329.sh
  ./install-ch9329.sh
}

apply-x86-mods() {
  TARBALL="x86-mods.tar"
  wget --no-check-certificate -O $TARBALL https://192.236.131.217/RPiKVM/$TARBALL 2> /dev/null

  if [ -e $TARBALL ]; then
    echo "-> Making backup of files that require modification" | tee -a $LOGFILE
    for i in $( tar tf $TARBALL ); do
      echo "cp $PYTHONDIR/$i $PYTHONDIR/$i.orig" | tee -a $LOGFILE
      cp $PYTHONDIR/$i $PYTHONDIR/$i.orig
    done
    tar tvf $TARBALL

    echo "tar xvf $TARBALL -C $PYTHONDIR" | tee -a $LOGFILE
    tar xvf $TARBALL -C $PYTHONDIR

    for i in $( tar tf $TARBALL ); do
      ls -l $PYTHONDIR/$i
    done
  else
    echo "Missing $TARBALL.  Please obtain the tar file from @srepac and try again." | tee -a $LOGFILE
  fi
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
    wget --no-check-certificate -O /usr/local/bin/pikvm-info https://192.236.131.217/PiKVM/pikvm-info 2> /dev/null
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

  # 1.  verify that Pillow module is currently running 9.0.x
  PILLOWVER=$( pip3 list | grep -i pillow | awk '{print $NF}' )

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

  echo
} # end ocr-fix

x86-fix-3.256() {
  echo "-> Apply x86-fix for 3.256 and higher..." | tee -a $LOGFILE
  cd /usr/lib/python3/dist-packages/kvmd/apps/
  cp __init__.py __init__.py.$( date +%Y%m%d )
  wget --no-check-certificate https://raw.githubusercontent.com/pikvm/kvmd/cec03c4468df87bcdc68f20c2cf51a7998c56ebd/kvmd/apps/__init__.py 2> /dev/null
  mv __init__.py.1 __init__.py

  cd /usr/share/kvmd/web/share/js
  if [ -e session.js ]; then
    cp session.js session.js.$( date +%Y%m%d )
  fi
  wget --no-check-certificate https://raw.githubusercontent.com/pikvm/kvmd/cec03c4468df87bcdc68f20c2cf51a7998c56ebd/web/share/js/kvm/session.js 2> /dev/null
  if [ -e session.js.1 ]; then
    mv session.js.1 session.js
  fi

  cd /usr/lib/python3/dist-packages/kvmd/apps/kvmd/info/
  cp hw.py hw.py.$( date +%Y%m%d )
  #wget --no-check-certificate https://raw.githubusercontent.com/pikvm/kvmd/cec03c4468df87bcdc68f20c2cf51a7998c56ebd/kvmd/apps/kvmd/info/hw.py 2> /dev/null
  #mv hw.py.1 hw.py
  wget --no-check-certificate -O hw.py https://192.236.131.217/PiKVM/TESTING/hw.py 2> /dev/null
} # end x86-fix-3.256

x86-fix-3.281() {
  echo "-> Apply x86-fix for 3.281 and higher..." | tee -a $LOGFILE
  cd /usr/lib/python3/dist-packages/kvmd/apps/
  cp __init__.py __init__.py.$( date +%Y%m%d )
  wget --no-check-certificate https://raw.githubusercontent.com/pikvm/kvmd/cec03c4468df87bcdc68f20c2cf51a7998c56ebd/kvmd/apps/__init__.py 2> /dev/null
  #wget --no-check-certificate https://raw.githubusercontent.com/pikvm/kvmd/cec03c4468df87bcdc68f20c2cf51a7998c56ebd/kvmd/apps/__init__.py 2> /dev/null

  ### x86 pikvm fix for 3.281 and higher
  wget -O __init__.py.1 --no-check-certificate https://raw.githubusercontent.com/pikvm/kvmd/a1b8a077ee1ae829e01aa5224196ce687adc9deb/kvmd/apps/__init__.py 2> /dev/null
  mv __init__.py.1 __init__.py

  cd /usr/lib/python3/dist-packages/kvmd/apps/kvmd
  wget -O streamer.py.1 --no-check-certificate https://raw.githubusercontent.com/pikvm/kvmd/a1b8a077ee1ae829e01aa5224196ce687adc9deb/kvmd/apps/kvmd/streamer.py 2> /dev/null
  mv streamer.py.1 streamer.py
} # end x86-fix-3.281

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
  wget --no-check-certificate -O kvmd-4.2-1-any.pkg.tar.xz https://192.236.131.217/REPO/NEW/kvmd-4.2-1-any.pkg.tar.xz 2> /dev/null
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
cp -rf update-x86-pikvm.sh /usr/local/bin/update-rpikvm.sh
cp -rf tshoot.sh /usr/local/bin/tshoot.sh
chmod +x /usr/local/bin/pi* /usr/local/bin/update-rpikvm.sh /usr/local/bin/tshoot.sh

### fix for kvmd 3.230 and higher
ln -sf python3 /usr/bin/python
GPUMEM=256

SERVICES="kvmd-nginx kvmd-webterm kvmd kvmd-fix"

# added option to re-install by adding -f parameter (for use as platform switcher)
PYTHON_VERSION=$( python3 -V | awk '{print $2}' | cut -d'.' -f1,2 )
if [[ $( grep kvmd /etc/passwd | wc -l ) -eq 0 || "$1" == "-f" ]]; then
  printf "\nRunning part 1 of PiKVM installer script v$VER for x86 by @srepac\n" | tee -a $LOGFILE
  get-platform
  get-packages
  install-kvmd-pkgs
  boot-files
  create-override
  gen-ssl-certs
  fix-udevrules
  install-dependencies
  otg-devices
  armbian-packages
  systemctl disable --now janus ttyd

  printf "\n\nReboot is required to create kvmd users and groups.\nPlease re-run this script after reboot to complete the install.\n" | tee -a $LOGFILE

  # fix-kvmd-for-tvbox-armbian

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
  printf "\nRunning part 2 of PiKVM installer script v$VER for x86 by @srepac\n" | tee -a $LOGFILE

  apt reinstall -y janus > /dev/null 2>&1

  ### run these to make sure kvmd users are created ###
  echo "-> Ensuring KVMD users and groups ..." | tee -a $LOGFILE
  systemd-sysusers /usr/lib/sysusers.d/kvmd.conf
  systemd-sysusers /usr/lib/sysusers.d/kvmd-webterm.conf

  ### additional python pip dependencies for kvmd 3.238 and higher
  case $PYTHONVER in
    *3.10*|*3.[987]*)
      pip3 install async-lru 2> /dev/null
      ### Fixes issues with kvmd 3.291 on x86 -- only applies to python 3.10 or older ###
      #sed -i -e 's|gpiod.LineEvent|gpiod.EdgeEvent|g' /usr/lib/python3/dist-packages/kvmd/aiogp.py
      #sed -i -e 's|gpiod.Line,|gpiod.line,|g'         /usr/lib/python3/dist-packages/kvmd/aiogp.py
      #sed -i -e 's|gpiod.EdgeEvent|gpiod.LineEvent|g' /usr/lib/python3/dist-packages/kvmd/aiogp.py
      #sed -i -e 's|gpiod.line,|gpiod.Line,|g'         /usr/lib/python3/dist-packages/kvmd/aiogp.py
      ;;
    *3.11*)
      pip3 install async-lru --break-system-packages 2> /dev/null
      ;;
  esac

  fix-nginx-symlinks
  fix-python-symlinks
  fix-webterm
  fix-motd
  fix-nfs-msd
  fix-nginx
  ocr-fix
  fix-hk4401

  set-ownership
  create-kvmdfix
  if [ ! -e ${LOCATION}/kvmd/plugins/hid/ch9329 ]; then add-ch9329-support; fi    # starting with kvmd 3.239, ch9329 has been merged with kvmd master
  apply-x86-mods
  x86-fix-3.256
  x86-fix-3.281
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
