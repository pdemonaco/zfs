#!/bin/bash
# ZFS Backup =======================================
#
# Provides a simple mechanism to backup a pool level
# snapshot to a series of files on a remote server
# via SSH

# Commands -----------------------------------------
awk=$(which awk)
grep=$(which grep)
ssh=$(which ssh)
sort=$(which sort)
tail=$(which tail)
uniq=$(which uniq)
xz=$(which xz)
zfs=$(which zfs)

# Functions ----------------------------------------
# Validate environment
check_env() {
  # Ensure environment is consistent
  if [[ -z $zfs || -z $xz ]]; then
    printf "error: zfs and xz are required!\n%s", "${usage}" >&2
    abort_flag=1
  # Should have four parameters
  elif [[ $parm_count -lt 4 ]]; then
    printf "error: all parameters are mandatory!\n%s", "${usage}" >&2
    abort_flag=2
  fi
}

# Find the most recent single
# snapshot matching $snap_format
get_snap() {
  $zfs list -Ht snapshot \
    | $awk 'BEGIN { FS="\t" } 
  { 
    split( $1, out, "@" ) 
    print out[2] 
  }' \
    | $grep $snap_format \
    | $sort \
    | $uniq \
    | $tail -n 1
}

# Determines the datasets to be backed up
get_datasets() {
  $zfs list -Hd 1 $pool \
    | $awk '
  { 
    num=split( $1, out, "/" )
    if (num > 1) print $1
  }'
}

# Usage --------------------------------------------
usage="Simple ZFS backup utility
usage: ./zfs_backup.sh <snap_format> <pool> <target> <path>

    snap_format     pattern to match snapshot name
    pool            zpool containing datasets
    target          backup target host
    path            path on backup host
"

# Initialize Variables -----------------------------
abort_flag=0
snap_name=""
hostname=$(hostname)

## Begin Execution ---------------------------------
# Gather Parameters
snap_format="$1"
pool="$2"
target="$3"
path="$4"
parm_count=$#

# Validate the environment
check_env

# Find a single uniq snapshot
if [[ $abort_flag -lt 1 ]]; then
  snap_name=$(get_snap)

  # Abort if no snapshot was identified 
  if [[ -z snap_name ]]; then
      abort_flag=3
  fi
fi

# Ensure the target directory exists
$ssh $target "mkdir -p ${path}/${hostname}"

# Perform the backup if possible
while read set_name && [[ $abort_flag -lt 1 ]]; do
  echo "Storing ${set_name}@${snap_name}"
  $zfs send -R ${set_name}@${snap_name} \
    | $ssh $target "cat - > ${path}/${hostname}/${set_name}_${snap_name}.img"
done < <(get_datasets)
 
exit $abort_flag
