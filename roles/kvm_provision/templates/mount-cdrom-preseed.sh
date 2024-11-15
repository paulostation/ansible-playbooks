#!/bin/bash

# Mount the ISO to /mnt
mount -t iso9660 /dev/cdrom /mnt

# Check if the ISO is mounted and if preseed.cfg exists
if [ -f /mnt/preseed.cfg ]; then
    # Set the preseed URL to the file path
    echo "Preseed file found, configuring installation with preseed.cfg"
    # Update the boot parameters to use the preseed.cfg
    echo "preseed/url=file:///mnt/preseed.cfg" > /tmp/preseed_configured
else
    echo "Preseed file not found in /mnt. Please check your ISO."
    exit 1
fi

