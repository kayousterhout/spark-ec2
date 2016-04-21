#!/bin/bash

# Disable Transparent Huge Pages (THP)
# THP can result in system thrashing (high sys usage) due to frequent defrags of memory.
# Most systems recommends turning THP off.
if [[ -e /sys/kernel/mm/transparent_hugepage/enabled ]]; then
  echo never > /sys/kernel/mm/transparent_hugepage/enabled
fi

# Make sure we are in the spark-ec2 directory
cd /root/spark-ec2

source ec2-variables.sh

# Set hostname based on EC2 private DNS name, so that it is set correctly
# even if the instance is restarted with a different private DNS name
PRIVATE_DNS=`wget -q -O - http://instance-data.ec2.internal/latest/meta-data/local-hostname`
hostname $PRIVATE_DNS
echo $PRIVATE_DNS > /etc/hostname
HOSTNAME=$PRIVATE_DNS  # Fix the bash built-in hostname variable too

echo "Setting up slave on `hostname`..."

# Mount options to use for xfs disks (we use xfs for EBS volumes to format them faster).
XFS_MOUNT_OPTS="defaults,noatime,nodiratime,allocsize=8m"
# ext4 has the best performance among ext3, ext4, and xfs based on our shuffle heavy benchmark
EXT4_MOUNT_OPTS="defaults,noatime,nodiratime"

instance_type=$(curl http://169.254.169.254/latest/meta-data/instance-type 2> /dev/null)
if [[ $instance_type == r3* || $instance_type == i2* ]]; then
  # Handle instances with disks that are not already formatted and mounted.
  rm -rf /mnt*
  mkdir /mnt
  # To turn TRIM support on, uncomment the following line.
  #echo '/dev/sdb /mnt  ext4  defaults,noatime,nodiratime,discard 0 0' >> /etc/fstab
  mkfs.ext4 -F -E lazy_itable_init=0,lazy_journal_init=0 /dev/sdb
  mount -o $EXT4_MOUNT_OPTS /dev/sdb /mnt

  if [[ $instance_type == "r3.8xlarge" || $instance_type == "i2.2xlarge" ]]; then
    mkdir /mnt2
    # To turn TRIM support on, uncomment the following line.
    #echo '/dev/sdc /mnt2  ext4  defaults,noatime,nodiratime,discard 0 0' >> /etc/fstab
    mkfs.ext4 -F -E lazy_itable_init=0,lazy_journal_init=0 /dev/sdc
    mount -o $EXT4_MOUNT_OPTS /dev/sdc /mnt2
  fi
else
  # For instance types where the storage volumes are already formatted and mounted, reformat them as
  # ext4.
  yum install -y xfsprogs
  for mnt in `mount | grep mnt | cut -d " " -f 3`; do
    device=$(df /$mnt | tail -n 1 | awk '{ print $1; }')
    empty=$(ls /$mnt | grep -v lost+found)
    if [[ "$empty" == "" ]]; then
      umount /$mnt
      mkfs.ext4 -F -E lazy_itable_init=0,lazy_journal_init=0 $device
      mount -o $EXT4_MOUNT_OPTS $device /$mnt
      echo "$device /$mnt auto $EXT4_MOUNT_OPTS 0 0" >> /etc/fstab
    fi
  done
fi

function setup_ebs_volume {
  device=$1
  mount_point=$2
  if [[ -e $device ]]; then
    # Check if device is already formatted
    if ! blkid $device; then
      mkdir $mount_point
      yum install -q -y xfsprogs
      if mkfs.xfs -q $device; then
        mount -o $XFS_MOUNT_OPTS $device $mount_point
        chmod -R a+w $mount_point
      else
        # mkfs.xfs is not installed on this machine or has failed;
        # delete /vol so that the user doesn't think we successfully
        # mounted the EBS volume
        rmdir $mount_point
      fi
    else
      # EBS volume is already formatted. Mount it if its not mounted yet.
      if ! grep -qs '$mount_point' /proc/mounts; then
        mkdir $mount_point
        mount -o $XFS_MOUNT_OPTS $device $mount_point
        chmod -R a+w $mount_point
      fi
    fi
  fi
}

# Format and mount EBS volume (/dev/sd[s, t, u, v, w, x, y, z]) as /vol[x] if the device exists
setup_ebs_volume /dev/sds /vol0
setup_ebs_volume /dev/sdt /vol1
setup_ebs_volume /dev/sdu /vol2
setup_ebs_volume /dev/sdv /vol3
setup_ebs_volume /dev/sdw /vol4
setup_ebs_volume /dev/sdx /vol5
setup_ebs_volume /dev/sdy /vol6
setup_ebs_volume /dev/sdz /vol7

# Alias vol to vol3 for backward compatibility: the old spark-ec2 script supports only attaching
# one EBS volume at /dev/sdv.
if [[ -e /vol3 && ! -e /vol ]]; then
  ln -s /vol3 /vol
fi

# Make data dirs writable by non-root users, such as CDH's hadoop user
chmod -R a+w /mnt*

# Remove ~/.ssh/known_hosts because it gets polluted as you start/stop many
# clusters (new machines tend to come up under old hostnames)
rm -f /root/.ssh/known_hosts

# Create swap space on /mnt
/root/spark-ec2/create-swap.sh $SWAP_MB

# Allow memory to be over committed. Helps in pyspark where we fork
# Don't do this in monotasks! It may be leading to OOM issues.
# We might even want to more aggressively override this to *never*
# overcommit memory (the default automatically determines when to overcommit).
#echo 1 > /proc/sys/vm/overcommit_memory

# Add github to known hosts to get git@github.com clone to work
# TODO(shivaram): Avoid duplicate entries ?
cat /root/spark-ec2/github.hostkey >> /root/.ssh/known_hosts

# Create /usr/bin/realpath which is used by R to find Java installations
# NOTE: /usr/bin/realpath is missing in CentOS AMIs. See
# http://superuser.com/questions/771104/usr-bin-realpath-not-found-in-centos-6-5
echo '#!/bin/bash' > /usr/bin/realpath
echo 'readlink -e "$@"' >> /usr/bin/realpath
chmod a+x /usr/bin/realpath
