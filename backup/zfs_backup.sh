#!/bin/bash
# ZFS Backup =======================================
#
# Provides a simple mechanism to backup a pool level
# snapshot to a series of files on a remote server
# via SSH or another local disk

# Commands -----------------------------------------
XZ=$(command -v xz)
ZFS=$(command -v zfs)

# Functions ----------------------------------------
# Validate environment
check_env() {
    # Ensure the script was run as root
    if [ "${EUID}" -ne 0 ]; then
        printf "error: must be run as root!\n%s" "${USAGE}" >&2
    # Ensure environment is consistent
    elif [[ -z "${ZFS}" ]]; then
        printf "error: zfs is required!\n%s" "${USAGE}" >&2
        ABORT_FLAG=1
    # If compression is enabled xz is required
    elif [[ -z "${XZ}" ]]; then
        printf "error: xz is required for compression!\n%s" "${USAGE}" >&2
        ABORT_FLAG=1
    # Check for mandatory parameters
    elif [[ -z "${POOL}" || -z "${TARGET_PATH}" || \
        -z "${SNAP_FORMAT}" ]]; then
        printf "error: -z, -f, and -p are mandatory!\n%s" "${USAGE}" >&2
        ABORT_FLAG=2
    # Ensure the path is not in the pool if it is not remote
    # TODO!!
    fi
}

# Find the most recent single
# snapshot matching $snap_format
get_snap() {
  $ZFS list -Ht snapshot \
    | awk 'BEGIN { FS="\t" } 
  { 
    split( $1, out, "@" ) 
    print out[2] 
  }' \
    | grep "${SNAP_FORMAT}" \
    | sort \
    | uniq \
    | tail -n 1
}

# Determines the datasets to be backed up
get_datasets() {
    if [[ "${ABORT_FLAG}" -lt 1 ]]; then
        $ZFS list -Hd 1 "${POOL}" \
            | awk '
        { 
            num=split( $1, out, "/" )
            if (num > 1) print $1
        }'
    fi
}

# Usage --------------------------------------------
USAGE="Simple ZFS backup utility
usage: ${0} -z <pool> -p <target-path> -f <snap-format>
    -h <remote-host> -c

Mandatory Arguments:
  -z  <pool>            zpool containing datasets
  -f  <snap-format>     pattern to match snapshot name
  -p  <target-path>     path in which to store the backups

Options:
  -h  <remote-host>     remote host to ssh the backup 
  -c                    enable compression via xz
"

# Initialize Variables -----------------------------
ABORT_FLAG=0
SNAP_NAME=""
HOSTNAME=$(hostname)
POOL=""
SNAP_FORMAT=""
TARGET_HOST=""
TARGET_PATH=""
COMPRESSION_FLAG=0


## Begin Execution ---------------------------------

while getopts "z:p:f:hc" OPT; do
    case "${OPT}" in
        z)
            POOL="${OPTARG}"
            ;;
        p)
            TARGET_PATH="${OPTARG}"
            ;;
        f)
            SNAP_FORMAT="${OPTARG}"
            ;;
        h)
            TARGET_HOST="${OPTARG}"
            ;;
        c)
            COMPRESSION_FLAG=1
            ;;
        :)
            printf "error: option \'%s\' requires an argument.\n%s" \
                "${OPTARG}" "${USAGE}" >&2
            ABORT_FLAG=1
            ;;
        *)
            printf "error: invalid option \'%s\'\n" \
                "${OPTARG}" >&2
            ABORT_FLAG=1
            ;;
    esac
done

# Validate the environment
check_env

# Perform necessary setup
if [[ $ABORT_FLAG -lt 1 ]]; then
    # Find a single unique snapshot
    SNAP_NAME=$(get_snap)

    # Abort if no snapshot was identified 
    if [[ -z "${SNAP_NAME}" ]]; then
        ABORT_FLAG=3
    fi
  
    # Ensure the destination directory exists
    if [[ -n "${TARGET_HOST}" ]]; then
        # shellcheck disable=SC2029
        ssh "${TARGET_HOST}" "mkdir -p ${TARGET_PATH}/${HOSTNAME}"
    else
        mkdir -p "${TARGET_PATH}/${HOSTNAME}"
    fi
fi


# Perform the backup if possible
while read -r SET_NAME && [[ $ABORT_FLAG -lt 1 ]]; do
    # Calculate the set prefix (remove '/')
    SET_PREFIX=${SET_NAME//\//_}

    # Build the target command
    if [[ -n "${TARGET_HOST}" ]]; then
        TARGET_CMD="| ssh \"${TARGET_HOST}\" \"cat - > ${TARGET_PATH}/${HOSTNAME}/${SET_PREFIX}_${SNAP_NAME}.img\""
    else
        TARGET_CMD="> \"${TARGET_PATH}/${HOSTNAME}/${SET_PREFIX}_${SNAP_NAME}.img\""
    fi
    
    # Build the send command
    if [[ ${COMPRESSION_FLAG} -eq 1 ]]; then
        SEND_CMD="$ZFS send -R \"${SET_NAME}@${SNAP_NAME}\" | $XZ"
    else
        SEND_CMD="$ZFS send -R \"${SET_NAME}@${SNAP_NAME}\""
    fi

    echo "Storing ${SET_NAME}@${SNAP_NAME}"
    echo "$SEND_CMD $TARGET_CMD"
    eval "$SEND_CMD $TARGET_CMD"
done < <(get_datasets)
 
exit $ABORT_FLAG
