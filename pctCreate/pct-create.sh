#!/bin/bash

#the location of your proxmox ct template should look like this
#	 __________________________________________________________________________
#	|									   |
#	|	/var/lib/vz/template/cache/debian-13-standard_13.1-2_amd64.tar.zst |
#	|	/var/lib/vz/template/cache/ct_lamp.tar.zst			   |
#	|__________________________________________________________________________|
#

echo $image
read -p "How many CTs do you need: " ctcount
read -p "What should be the starting ID: " ctstart
read -p "What bridge should they use ?(vmbr1): " ctbridge
read -p "What is the gateway of the bridge ? (PMX host ip on the bridge): " ctgw
read -p "What is the name of your template ? (CT_IMAGE.zst): " ctimage
read -p "How many cores: " ctcores
read -p "How much RAM in MiB: " ctram
read -p "How many GiB storage: " ctstorage
read -p "should it be unpriviliged(1/0)" ctpriv

#for loop that builds ct

for ((i = 0; i < $ctcount; i++)); do
#buidling proper ip
	

	echo "------ Creation of CT $ctid started ------"


		pct create $ctid local:vztmpl/$ctimage \


        	--hostname ct$ctid \
        	--cores $ctcores \
        	--memory $ctram \
        	--rootfs local-lvm:$ctstorage \
        	--features nesting=1 \
        	--net0 name=eth0,bridge=$ctbridge,ip=192.168.1.$ip_suffix/24,gw=$ctgw \
        	--unprivileged $ctpriv \
        	--start 1
 
	echo "------ CT $ctid created and started ------"
done
