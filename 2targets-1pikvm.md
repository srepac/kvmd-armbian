QUICK HOW TO "ONE PIKVM - TWO TARGETS" by @srepac

- Have you ever wanted to control multiple targets without a KVM switch using only one PiKVM?  If so, this solution is exactly for you.  In place of the x86 pikvm, you can also use RPi 3B with hdmi USB platform aka kvmd-platform-v0-hdmiusb-rpi3  https://192.236.131.217:8443/IMAGES/v0-hdmiusb-rpi3-20230423.img.xz

REQUIREMENTS:
- x86pikvm  https://github.com/srepac/kvmd-armbian/blob/master/How%20to%20Install%20PiKVM%20x86.pdf 
- 2x uart + ch9329 (one per target)
- 2x usb hdmi (one per target)

VIDEO IN ACTION:
- https://discord.com/channels/580094191938437144/580858755827367956/1194307516838977598

Overview steps:

1.  Create x86 pikvm per the doc above.  Connect one pair of uart + ch9329 and usb hdmi per target.

2.  Setup scripts in /usr/local/bin/ for use by GPIO menu.  The ln -sf commands may need to be edited to reflect the correct devices used for your target 1 and target 2.  In my case, I confirmed the first target used ttyUSB0 and video0, before connecting the next target uart + usb hdmi to the x86 PC.
```
[root@x86kvm bin]# pwd
/usr/local/bin
[root@x86kvm bin]# ls -l ch_reset.py target.sh
-rwxr-xr-x 1 root root 471 Aug 25 16:45 ch_reset.py
-rwxr-xr-x 1 root root 384 Jan  9 08:21 target.sh

[root@x86kvm bin]# cat target.sh
#!/bin/bash
function usage() {
  echo "usage:  $0 [#]  where # is the target number to switch to."
  exit 1
}

function perform-change() {
  set -x
  echo "$USB,$VID,$TGT" > $CONFIG
  ln -sf $USB /dev/kvmd-hid
  ln -sf $VID /dev/kvmd-video
  systemctl restart kvmd    # restart kvmd services after changing hid
  sleep 2
  ch_reset.py   # reset ch9329 so it's fresh once we change targets
  ls -l /dev/kvmd*
  set +x
}

function show-config() {
  CONFIG="/etc/kvmd/current-target"
  if [ -e $CONFIG ]; then
    USB=$( cat $CONFIG | cut -d',' -f1 )
    VID=$( cat $CONFIG | cut -d',' -f2 )
    TGT=$( cat $CONFIG | cut -d',' -f3 )
    NUM=$( echo $TGT | sed 's/target//g' )
    echo "-> Current target info:  $USB,$VID,$TGT"
    ls -l /dev/kvmd*
  else
    NUM=1     # CONFIG file does not exist so default is target 1
  fi
}


### MAIN STARTS HERE ###
show-config

if [ $# -eq 0 ]; then
  echo "*** Missing target number. ***"
  usage
fi

case $1 in
  1) if [ $1 -ne $NUM ] ; then
       echo "-> Control change to target $1.  Please wait..."
       USB="ttyUSB0"
       VID="video0"
       TGT="target$1"
       perform-change
     else
       echo "-> Target you want is already set to $NUM"
     fi
     ;;
  2) if [ $1 -ne $NUM ]; then
       echo "-> Control change to target $1.  Please wait..."
       USB="ttyUSB1"
       VID="video2"
       TGT="target$1"
       perform-change
     else
       echo "-> Target you want is already set to $NUM"
     fi
     ;;

  -h|--help)
     usage
     ;;

  *) echo "*** Target not defined.  Exiting. ***"
     exit 1
     ;;
esac


[root@x86kvm bin]# cat ch_reset.py
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
```

**NOTE:  Before moving on to the next step, make sure that you see two sets of prolific (uart+ch9329) and macrosilicon (usb hdmi) usb devices**
```
[root@x86kvm ~]# lsusb
Bus 003 Device 001: ID 1d6b:0003 Linux Foundation 3.0 root hub
Bus 002 Device 005: ID 534d:2109 MacroSilicon
Bus 002 Device 004: ID 067b:2303 Prolific Technology, Inc. PL2303 Serial Port / Mobile Action MA-8910P
Bus 002 Device 003: ID 067b:2303 Prolific Technology, Inc. PL2303 Serial Port / Mobile Action MA-8910P
Bus 002 Device 002: ID 534d:2109 MacroSilicon
```

3.  Setup sudoers to allow kvmd user to perform any commands
```
[root@x86kvm bin]# cat /etc/sudoers.d/custom_commands
kvmd ALL=(ALL) NOPASSWD: ALL
```

4.  Setup override to show target buttons in GPIO menu 
```[root@x86kvm bin]# cat /etc/kvmd/override.d/ch9329.yaml
kvmd:
    gpio:
        drivers:
            ch_reset:
                type: cmd
                cmd: [/usr/local/bin/ch_reset.py]
            target1:
                type: cmd
                cmd: [/usr/bin/sudo, /usr/local/bin/target.sh, 1]
            target2:
                type: cmd
                cmd: [/usr/bin/sudo, /usr/local/bin/target.sh, 2]

        scheme:
            ch_reset_button:
                driver: ch_reset
                pin: 0
                mode: output
                switch: false
            target1_button:
                driver: target1
                pin: 1
                mode: output
                switch: false
            target2_button:
                driver: target2
                pin: 2
                mode: output
                switch: false

        view:
            table:
                - []
                - ["#CUSTOM SCRIPTS"]
                - []
                - ["#ch_reset.py", "ch_reset_button|Reset CH9329 HID"]
                - []
                - ["#CHANGE TARGETS - requires webui restart"]
                - []
                - ["#TARGET1", "target1_button|Target1"]
                - ["#TARGET2", "target2_button|Target2"]
```

5.  Add the default target 1 symlink changes to /usr/bin/kvmd-fix.  **NOTE:  Please make sure this matches your target 1 serial hid and video**
```
#!/bin/bash
# Written by @srepac
#
### These fixes are required in order for kvmd service to start properly
#
set -x

### setup the default target system
CONFIG="/etc/kvmd/current-target"
if [ -e $CONFIG ]; then
  USB=$( cat $CONFIG | cut -d',' -f1 )
  VID=$( cat $CONFIG | cut -d',' -f2 )
  TGT=$( cat $CONFIG | cut -d',' -f3 )
else
  TGT="target1"
  USB="ttyUSB0"
  VID="video0"
  echo "$USB,$VID,$TGT" > $CONFIG
fi
ln -sf $USB /dev/kvmd-hid
ln -sf $VID /dev/kvmd-video
echo "Controlling $TGT"
systemctl restart kvmd
ls -l /dev/kvmd*

set +x
```

6.  Enjoy!
