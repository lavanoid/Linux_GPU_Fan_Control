#!/bin/bash

# My hacked together version of cool_gpu2.sh, which allows for headless GPU fan control on Linux. Both AMD (using the amdgpu driver) and NVIDIA graphics cards are supported!
# Works on the current version of the NVIDIA driver as of 2021-03-12
# This script works by generating a new xconfig for each GPU and setting them as the primary device.
    
# Paths to the utilities we will need
SMI=$(which nvidia-smi)
SET=$(which nvidia-settings)

# Determine major driver version
VER=$(awk '/NVIDIA/ {print $8}' /proc/driver/nvidia/version | cut -d . -f 1)

if [ "$EUID" -ne 0 ]
  then echo "This script needs to be ran as root!"
  exit 1
fi


function busFix() {
    BUS=$((10#$(echo $1 | cut -d: -f1) + 0))
    DEV=$((10#$(echo $1 | cut -d: -f2 | cut -d. -f1) + 0))
    FUN=$((10#$(echo $1 | cut -d. -f2) + 0))
    echo $BUS:$DEV:$FUN
}

function backupX() {
    if [[ -f "/etc/X11/xorg.conf" ]]; then
        echo "Backing up xconfig..."
        cat /etc/X11/xorg.conf > /etc/X11/xorg.conf.backup
    fi
}

function restoreX() {
    if [[ -f "/etc/X11/xorg.conf.backup" ]]; then
        echo "Restoring xconfig..."
        cat /etc/X11/xorg.conf.backup > /etc/X11/xorg.conf
    fi
}

function generateX() {
    # First argument should be the bus ID
    
    echo "Generating xconfig..."
    nvidia-xconfig --allow-empty-initial-configuration --cool-bits=28 --busid=PCI:$1 --device=Device0 &> /dev/null
}

function setFanState() {
    # $1: 1 = Manual, 0 = Auto
    # $2: Fan Speed
    
    if [[ "$1" == "1" ]]; then
    
        if [ "$2" -eq "$2" ] 2>/dev/null && [ "0$2" -ge "40" ]  && [ "0$2" -le "100" ]; then
            echo "Setting manual fan speed of $2%..."
        
            xinit ${SET} -a [gpu:0]/GPUFanControlState=1 -a [fan:0]/GPUTargetFanSpeed=$2 -- :0 -once &> /dev/null
            
            # Disable the GeForce LED on 10 series and older cards.
            xinit ${SET} --assign GPULogoBrightness=0 &> /dev/null
        else
            echo "Invalid fan speed!"
        fi
    else
        echo "Setting automatic fan speed..."
        xinit ${SET} -a [gpu:0]/GPUFanControlState=0 -- :0 -once &> /dev/null
    fi
}

function setFanStateAMD() {
    # $1: 1 = Manual, 0 = Auto
    # $2: Fan Speed
    
    if [[ "$1" == "1" ]]; then
    
        if [ "$2" -eq "$2" ] 2>/dev/null && [ "0$2" -ge "40" ]  && [ "0$2" -le "100" ]; then
            speed=$(($2 * 255 / 100))
            #echo "Setting manual fan speed of $2% ($speed)..."
            
            ls -d1 /sys/class/drm/card*/device/hwmon/hwmon* | while read -r dir; do
                echo "Applying changes to: $dir"
                echo 1 > "$dir/pwm1_enable"
                echo $speed > "$dir/pwm1"
            done
            
        else
            echo "Invalid fan speed!"
        fi
    else
        echo "Setting automatic fan speed..."
        ls -d1 /sys/class/drm/card*/device/hwmon/hwmon* | while read -r dir; do
                echo "Applying changes to: $dir"
                echo 0 > "$dir/pwm1_enable"
            done
    fi
}

function findAMDGPU() {
    #/sys/class/drm/card0/device/hwmon/hwmon0/
    if [[ -d "/sys/class/drm" ]]; then
        ls -d1 /sys/class/drm/card*/device/hwmon/hwmon* | wc -l
    fi
}

function applyChanges() {
    # $1: 1 = Manual, 0 = Auto
    # $2: Fan speed
    
    amdgputotal=$(findAMDGPU)
    nvgputotal=$($SMI --query-gpu=pci.bus_id,gpu_name --format=csv,noheader | wc -l)
    
    if [[ $amdgputotal -gt 0 ]]; then
        echo "AMD GPU found ($amdgputotal)!"
        setFanStateAMD 1 $2
    fi
    
    if [[ $nvgputotal -gt 0 ]]; then
        echo "NVIDIA GPU found ($nvgputotal)!"

        # Drivers from 285.x.y on allow persistence mode setting
        if [ ${VER} -lt 285 ]; then
            echo "Error: Current driver version is ${VER}. Driver version must be greater than 285."; exit 1;
        fi

        backupX
        rm -f /etc/X11/xorg.conf
    
        # loop through each GPU and individually set fan speed
        $SMI --query-gpu=pci.bus_id,gpu_name --format=csv,noheader | while read -r line; do
            $SMI -pm 1 # enable persistance mode
            BUS_ID=$(echo $line | cut -d, -f1 | cut -d: -f2-3)
            NAME=$(echo $line | cut -d, -f2 | sed -e 's/^[ \t]*//')

            echo -e "########################################\
\nGPU BUS: $BUS_ID\
\nGPU BUS FIXED: "$(busFix $BUS_ID)\
"\nGPU NAME: '$NAME'\
\n########################################"
        
            generateX $(busFix $BUS_ID)
        
            if [[ "$1" == "0" ]]; then
                # Auto fan speed
                # disable persistance mode
                $SMI -pm 0
                
                setFanState 0
            else
                # Manual fan speed
                setFanState 1 $2
                
                # set some overclocks
                 #xinit ${SET} -a [gpu:0]/GPUMemoryTransferRateOffset[2]=500 > /dev/null 2>&1
                 #xinit ${SET} -a [gpu:0]/GPUMemoryTransferRateOffset[3]=500 > /dev/null 2>&1
            fi
        done
    
        restoreX
        sleep 2
        $SMI
    fi
}

# Read a numerical command line arg between 40 and 100
if [ "$1" -eq "$1" ] 2>/dev/null && [ "0$1" -ge "40" ]  && [ "0$1" -le "100" ]; then
    echo "Setting fan to $1%."

    # start an x session, and call nvidia-settings to enable fan control and set speed
    applyChanges 1 $1

    echo "Complete"
else
    if [[ "$1" == "auto" ]]; then
        

        echo "Enabling default auto fan control."
        applyChanges 0
        echo "Complete"

    else
        echo "Error: Please pick a fan speed between 40 and 100, or auto."
        exit 1
    fi
fi
