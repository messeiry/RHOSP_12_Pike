#!/bin/bash

permit_ssh()
{
  # Permit root login over SSH
  sed -i 's/.*ssh-rsa/ssh-rsa/' /root/.ssh/authorized_keys
  sed -i 's/PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
  sed -i 's/ChallengeResponseAuthentication.*/ChallengeResponseAuthentication yes/g' /etc/ssh/sshd_config
  
  systemctl restart sshd
}

set_rootpw()
{
  # Update the root password to something we know
  echo changeme | sudo passwd root --stdin
}

rp_filter_accept()
{
  # configure rp filter to accept packets on all links
  echo 2 > /proc/sys/net/ipv4/conf/all/rp_filter
}

replace_partx()
{
  # if partx is still broken we replace it by a script that simulates it
  if [ ! -e /usr/sbin/partx.org ]; then
    mv /usr/sbin/partx /usr/sbin/partx.org
    cat <<"END" > /usr/sbin/partx
#!/bin/bash
[[ $1 = *"dev"* ]] && DEV="$1" || DEV="$2"
/usr/sbin/partx.org -u ${DEV}
echo "`date` partx $@" >> /tmp/partx.out
exit 0
END
    chmod 755 /usr/sbin/partx
    #ln -s /bin/true /usr/sbin/partx
  fi
}

wipe_disks()
{
  # This script wipes all disks except for the root disk to make sure there's nothing
  # left from a previous install and to have GPT labels in place.
  export LVM_SUPPRESS_FD_WARNINGS=true
  echo -e "\nPreparing disks for local storage usage...\n================================================="
  echo "Number of disks detected: $(lsblk -no NAME,TYPE,MOUNTPOINT | grep "disk" | awk '{print $1}' | wc -l)"
  echo "Number of mpath devices: $(ls /dev/mapper/mpath[a-z] 2>/dev/null | wc -l)"
  multipath -ll
  DISKDEVS=""
  vgchange -an 2>/dev/null
  for VG in `vgs --noheadings --rows|head -1`; do
    vgremove -f $VG
  done
  cd /dev
  for DEVICE in `lsblk -no NAME,TYPE,MOUNTPOINT | grep "disk" | awk '{print $1}'` mapper/mpath[a-z]; do
    ROOTFOUND=0
    echo "Checking /dev/$DEVICE..."
    [ -e /dev/$DEVICE ] || continue
    echo "Number of partitions on /dev/$DEVICE: $(expr $(lsblk -n /dev/$DEVICE | awk '{print $7}' | wc -l) - 1)"
    for MOUNTS in `lsblk -n /dev/$DEVICE | awk '{print $7}'`; do
      if [ "$MOUNTS" = "/" ]; then
        ROOTFOUND=1
      fi
    done
    if [ $ROOTFOUND = 0 ]; then
      echo "Root not found in /dev/${DEVICE}"
      # if this device is part of an mpath we skip it
      lsblk -n /dev/$DEVICE 2>/dev/null | paste -s | grep disk | grep mpath && echo "/dev/${DEVICE} is an mpath device... skipping." && continue
      echo "Wiping disk /dev/${DEVICE}"
      partx -d /dev/${DEVICE}
      sgdisk -Z /dev/${DEVICE}
      sgdisk -g /dev/${DEVICE}
      partx -a /dev/${DEVICE}
      partx -u /dev/${DEVICE}
      DISKDEVS="${DISKDEVS} ${DEVICE}"
      lsblk -no SIZE -db /dev/${DEVICE}
      sync
    else
      echo "Root found in /dev/${DEVICE}... skipping."
    fi
  done
}

prep_cheph_disks()
{
  if [[ `hostname` = *"ceph"* ]]; then
    wipe_disks
  fi
}

prep_ceph_journal_partition()
{
  # for Ceph that needs to have a first partition in place
  if [[ `hostname` = *"ceph"* ]]; then
        for i in {d,e,f,g}; do
                if [ -b /dev/sd${i} ]; then
                        echo "Wiping disk /dev/sd${i} and creating journal partition..."
                        sgdisk -Z /dev/sd${i}
                        sgdisk -g /dev/sd${i}
                        sgdisk -n 1:2048:10487808 -t 1:FFFF -c 1:"ceph journal" -g /dev/sd${i};
                fi
        done
  fi
}

prep_local_storage()
{
# This script contains a procedure to extend the controllers and computes local
# storage. It wipes all disks except for the root disk to make sure there's nothing
# left from a previous install and to have GPT labels in place. It then adds
# space to glance (image), cinder (block) and swift (object).
if [[ `hostname` = *"control"* ]] || [[ `hostname` = *"compute"* ]]; then
  wipe_disks
  export LVM_SUPPRESS_FD_WARNINGS=true
  echo -e "\nPreparing disks for local storage usage...\n================================================="
  echo "Number of disks detected: $(lsblk -no NAME,TYPE,MOUNTPOINT | grep "disk" | awk '{print $1}' | wc -l)"
  echo "Number of mpath devices: $(ls /dev/mapper/mpath[a-z] 2>/dev/null | wc -l)"
  multipath -ll
  DISKDEVS=""
  cd /dev
  for DEVICE in `lsblk -no NAME,TYPE,MOUNTPOINT | grep "disk" | awk '{print $1}'` mapper/mpath[a-z]; do
    ROOTFOUND=0
    echo "Checking /dev/$DEVICE..."
    [ -e /dev/$DEVICE ] || continue
    echo "Number of partitions on /dev/$DEVICE: $(expr $(lsblk -n /dev/$DEVICE | awk '{print $7}' | wc -l) - 1)"
    for MOUNTS in `lsblk -n /dev/$DEVICE | awk '{print $7}'`; do
      if [ "$MOUNTS" = "/" ]; then
        ROOTFOUND=1
      fi
    done
    if [ $ROOTFOUND = 0 ]; then
      echo "Root not found in /dev/${DEVICE}"
      # if this device is part of an mpath we skip it
      lsblk -n /dev/$DEVICE 2>/dev/null | paste -s | grep disk | grep mpath && echo "/dev/${DEVICE} is an mpath device... skipping." && continue
      lsblk -no SIZE -db /dev/${DEVICE}

      echo "Partitioning disk /dev/${DEVICE}"
      # vg: cinder-volumes
      # /var/lib/glance
      # /var/cache/swift
      # /srv/node
      # /var/lib/nova
      # partition to 50% glance/swift/nova and 50% cinder (if controller)
      [[ `hostname` = *"control"* ]] && PSIZE="$((`lsblk -no SIZE -db /dev/${DEVICE}`/1024/1024/1024/2))G" || PSIZE="0"
      sgdisk -n 0:0:$PSIZE -c "vg_storage" /dev/${DEVICE}
      dd if=/dev/zero of=/dev/${DEVICE}1 bs=100M count=1
      if [[ `hostname` = *"control"* ]]; then
        sgdisk -n 0:0:0 -c "cinder-volumes" /dev/${DEVICE}
        dd if=/dev/zero of=/dev/${DEVICE}2 bs=500M count=6
      fi
      partx -a /dev/${DEVICE}
      partx -u /dev/${DEVICE}
      sync
    else
      echo "Root found in /dev/${DEVICE}... skipping."
    fi
  done

  echo -e "\nCleaned all disks, continuing to partition now...\n================================================="
  partprobe
  vgchange -an
  vgs
  lvs
  
  for DEVICE in ${DISKDEVS}; do
      echo "Creating LV vg_storage/lv_storage on /dev/${DEVICE}1"
      pvcreate /dev/${DEVICE}1
      if vgs | grep vg_storage; then
        vgextend vg_storage /dev/${DEVICE}1
        lvextend /dev/mapper/vg_storage-lv_storage /dev/${DEVICE}1
      else
        vgcreate vg_storage /dev/${DEVICE}1
        lvcreate -n lv_storage -l 100%FREE vg_storage
      fi
      if [[ `hostname` = *"control"* ]]; then
        echo "Creating VG cinder-volumes on /dev/${DEVICE}2"
        pvcreate /dev/${DEVICE}2
        if vgs | grep cinder-volumes; then
          vgextend cinder-volumes /dev/${DEVICE}2
        else
          vgcreate cinder-volumes /dev/${DEVICE}2
        fi
      fi
  done

  echo -e "\nPrepared all disks, continuing to change fs layout now...\n================================================="
  echo "Creating XFS filesystem on /dev/mapper/vg_storage-lv_storage"
  if vgs | grep vg_storage && mkfs.xfs /dev/mapper/vg_storage-lv_storage; then
    mkdir -p /srv/storage
    echo "/dev/mapper/vg_storage-lv_storage     /srv/storage     xfs    defaults            1 2" >> /etc/fstab
    mount -a 
    for n in /srv/node /var/lib/nova /var/lib/glance /var/cache/swift; do
      [ -d "$n" ] || continue
      rsync -aviPHAXS $n /srv/storage/
      rm -Rf $n/*
      echo "/srv/storage/`basename $n`          $n     none   bind     0 0" >> /etc/fstab
    done
    sync
    mount -a
  else
    echo "No additional data disk found."
  fi
  echo -e "\ndone.\n================================================="
fi
}

patch_pcsd()
{
  ( while  ! yum -y --enablerepo=rhel-server-rhscl-7-rpms install rh-ruby22 2>/dev/null; do sleep 1m; done
    sed -i -e "s/'::'/'0.0.0'/" /usr/lib/pcsd/ssl.rb
    sed -i -e "s|^ExecStart=\(.*\)|ExecStart=/bin/scl enable rh-ruby22 -- \1|" /usr/lib/systemd/system/pcsd.service
    systemctl daemon-reload
    pgrep -af pcsd
    if [ "$?" = "0" ]; then
      systemctl stop pcsd
      killall pcsd
      systemctl start pcsd
    fi ) &
}


permit_ssh
set_rootpw
#rp_filter_accept
replace_partx
prep_cheph_disks

#prep_ceph_journal_partition
#prep_local_storage
#patch_pcsd

exit 0
