#!/bin/bash -u

function main() {
	# Load configuration parameter
	source config.sh

	# Load functions
	source common/confirmation.sh
	source common/preinstall.sh
	source common/parainstall.sh
	source common/parainstall_msg.sh


	# This is the mount point of the install target. 
	export TARGETMOUNTPOINT="/mnt/target"

	# Distribution check
	if ! uname -a | grep void -i > /dev/null ; then	# "Void" is not found in the OS name.
		echo "*********************************************************************************"
		uname -a
		cat <<- HEREDOC 
		*********************************************************************************
		This system seems to be not Void Linux, while this script is dediated to the Void Linux.
		Are you sure you want to run this script for installation? [Y/N]
		HEREDOC
		read YESNO
		if [ ${YESNO} != "Y" -a ${YESNO} != "y" ] ; then
			cat <<- HEREDOC 1>&2

			...Installation process terminated..
			HEREDOC
			return
		fi	# if YES

	fi # "Void" is not found in the OS name.

	# ******************************************************************************* 
	#                                Confirmation before installation 
	# ******************************************************************************* 

	# Common part of the parameter confirmation
	if ! confirmation ; then
		return 1 # with error status
	fi

	# ******************************************************************************* 
	#                                Pre-install stage 
	# ******************************************************************************* 

	# Install essential packages.
	xbps-install -y -Su xbps gptfdisk xterm

	# Common part of the pre-install stage
	if ! pre_install ; then
		return 1 # with error status
	fi

	# ADD "rd.auto=1 cryptdevice=/dev/sda2:${CRYPTPARTNAME} root=/dev/mapper/${VGNAME}-${ROOTNAME}" to GRUB.
	# This is magical part. I have not understood why this is required. 
	# Anyway, without this modification, Void Linux doesn't boot. 
	# Refer https://wiki.voidlinux.org/Install_LVM_LUKS#Installation_using_void-installer
	echo "...Modify /etc/default/grub."
	sed -i "s#loglevel=4#loglevel=4 rd.auto=1 cryptdevice=${DEV}${CRYPTPARTITION}:${CRYPTPARTNAME} root=/dev/mapper/${VGNAME}-${LVROOTNAME}#" /etc/default/grub

	# ******************************************************************************* 
	#                                Para-install stage 
	# ******************************************************************************* 

	# Show common message to let the operator focus on the critical part
	parainstall_msg
	# Ubuntu dependent message
	cat <<- HEREDOC

	************************ CAUTION! CAUTION! CAUTION! ****************************
	
	Make sure to click "NO", if the void-installer ask you to reboot.
	Just exit the installer without rebooting. Other wise, your system
	is unable to boot. 

	Type return key to start void-installer.
	HEREDOC

	# waitfor a console input
	read dummy_var

	# Start void-installer in the separate window
	xterm -fa monospace -fs ${XTERMFONTSIZE} -e void-installer &
	
	# Record the PID of the installer. 
	export INSTALLER_PID=$!

	# Common part of the para-install. 
	# Record the install PID, modify the /etc/default/grub of the target, 
	# and then, wait for the end of sintaller. 
	if ! parainstall ; then
		return 1 # with error status
	fi

	# ******************************************************************************* 
	#                                Post-install stage 
	# ******************************************************************************* 

	## Mount the target file system
	# ${TARGETMOUNTPOINT} is created by the GUI/TUI installer
	echo "...Mount /dev/mapper/${VGNAME}-${LVROOTNAME} on ${TARGETMOUNTPOINT}."
	mount /dev/mapper/${VGNAME}-${LVROOTNAME} ${TARGETMOUNTPOINT}

	# And mount other directories
	echo "...Mount all other dirs."
	for n in proc sys dev etc/resolv.conf; do mount --rbind "/$n" "${TARGETMOUNTPOINT}/$n"; done

	# Change root and create the keyfile and ramfs image for Linux kernel. 
	echo "...Chroot to ${TARGETMOUNTPOINT}."
	cat <<- HEREDOC | chroot ${TARGETMOUNTPOINT} /bin/bash
	# Mount the rest of partitions by target /etc/fstab
	mount -a

	# Set up the kernel hook of encryption
	echo "...Install cryptsetup-initramfs package."
	xbps-install -y lvm2 cryptsetup

	# Prepare a key file to embed in to the ramfs.
	echo "...Prepair key file."
	mkdir /etc/luks
	dd if=/dev/urandom of=/etc/luks/boot_os.keyfile bs=4096 count=1 status=none
	chmod u=rx,go-rwx /etc/luks
	chmod u=r,go-rwx /etc/luks/boot_os.keyfile

	# Add a key to the key file. Use the passphrase in the environment variable. 
	echo "...Add a key to the key file."
	printf %s "${PASSPHRASE}" | cryptsetup luksAddKey -d - "${DEV}${CRYPTPARTITION}" /etc/luks/boot_os.keyfile

	# Add the LUKS volume information to /etc/crypttab to decrypt by kernel.  
	echo "...Add LUKS volume info to /etc/crypttab."
	echo "${CRYPTPARTNAME} UUID=$(blkid -s UUID -o value ${DEV}${CRYPTPARTITION}) /etc/luks/boot_os.keyfile luks,discard" >> /etc/crypttab

	# Putting key file into the ramfs initial image
	echo "...Register key file to the ramfs"
	echo 'install_items+=" /etc/luks/boot_os.keyfile /etc/crypttab " ' > /etc/dracut.conf.d/10-crypt.conf

	# Finally, update the ramfs initial image with the key file. 
	echo "...Upadte initramfs."
	xbps-reconfigure -fa
	echo "...grub-mkconfig."
	grub-mkconfig -o /boot/grub/grub.cfg
	echo "...update-grub."
	update-grub

	# Leave chroot
	HEREDOC

	# Unmount all
	echo "...Unmount all."
	umount -R ${TARGETMOUNTPOINT}

	# Finishing message
	cat <<- HEREDOC
	****************** Post-install process finished ******************

	...Ready to reboot.
	HEREDOC

	# Normal end
	return 0
}

# Execute
main