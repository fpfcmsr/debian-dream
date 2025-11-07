#!/bin/bash

# make sure to run the below in the terminal to get disk IDs
# ls -l /dev/disk/by-id | grep -E 'nvme-|ata-|scsi-|wwn-' | grep -v -- '-part[0-9]\+$'  
# lsblk -d -o NAME,SIZE,MODEL,SERIAL,TYPE,TRAN  

# set environment variables
export LUKS_PASSPHRASE='correct-horse-battery-staple'
export NEWUSER_PASSWORD='apassword'
export HOSTNAME=ahostname
export USERNAME=myusername
export DISK1=/dev/disk/by-id/ID-yougot-above-1
export DISK2=/dev/disk/by-id/ID-yougot-above-2
