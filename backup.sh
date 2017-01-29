#!/bin/bash

### FUNCTIONS ###

include_file ()
{ # check stated file and include if present
    FILE="$( realpath ${1} )"
    if [ ! -f "${FILE}" ]; then
        echo "${FILE} is not present. Aborting..."
        exit 1
    else
        source ${FILE}
    fi
}

require_command ()
{ # check if the needed command is present
    COMMAND="$(command -v ${1})"
    if [ -z ${COMMAND} ]; then
        echo "${1} seems not available. This script can not be executed without it."
        exit 1
    else
        echo "${COMMAND}"
    fi
}

get_running_containers ()
{ # get a list of all running containers and put the names into an array
    DOCKER="$(require_command docker) ps"

    ${DOCKER} --format '{{.Names}}' 
}

get_container_volumes ()
{ # use ${1} as container-name and extract mounted volumes
    CONTAINER_NAME="${1}"
    DOCKER="$(require_command docker) inspect"

    ${DOCKER} --format '{{ range .Mounts }}{{ .Source }} {{ end }}' ${CONTAINER_NAME}
}

create_dir ()
{ # use ${1} as directory and check if it is present
    DIR="${1}"
    if [ ! -d ${DIR} ]; then
        mkdir -p ${DIR}
    fi
}

backup_directory ()
{ # use ${1} as destination and ${2} as backup-source 
    DESTINATION="${1}"
    SOURCE="${2}"
    
    if [ ! -r ${SOURCE} ] || [ ! $($(require_command touch) ${DESTINATION}) ]; then
        echo "Either source or desitnation file is not accessible. Aborting..."
        exit 1
    fi

    TAR="$(require_command tar)"
    ARGUMENTS="-cpzf"
    ${TAR} ${ARGUMENTS} ${DESTINATION} ${SOURCE}
}

### FINISHED FUNCTIONS ###

### CONFIG ###

# Get full path of current directory
unset SCRIPTDIR
SCRIPTDIR=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)

# Default config location
unset CONFIG
CONFIG="${SCRIPTDIR}"/backup.cfg

# Check if own config is stated
if [ "${1}" == "--config" ]; then
    # Get config from specified file
    CONFIG="${2}"
elif [ ${#} != 0 ]; then
    # Invalid arguments
    echo "Usage: $0 [--config filename]"
    exit 1
fi

include_file "${CONFIG}"

### FINISHED CONFIG ###

### CHECKS ###

# This section checks for all of the binaries used in the backup
if [ ! -z ${MAILRCPT} ]; then
    BINARIES=( ssmtp mkdir cat cd command date dirname echo find openssl pwd realpath rm rsync scp ssh tar sed )
else
    BINARIES=( mkdir cat cd command date dirname echo find openssl pwd realpath rm rsync scp ssh tar sed )
fi

# Iterate over the list of binaries, and if one isn't found, abort
for BINARY in "${BINARIES[@]}"; do
    if [ ! "$(command -v "$BINARY")" ]; then
        log "$BINARY is not installed. Install it and try again"
        exit 1
    fi
done

# Check if the backup folders exist and are writeable
if [ ! -w "${LOCALDIR}" ]; then
    log "${LOCALDIR} either doesn't exist or isn't writable"
    log "Either fix or replace the LOCALDIR setting"
    exit 1
elif [ ! -w "${TEMPDIR}" ]; then
    log "${TEMPDIR} either doesn't exist or isn't writable"
    log "Either fix or replace the TEMPDIR setting"
    exit 1
fi

# Check that SSH login to remote server is successful
if [ ! "$(ssh -oBatchMode=yes -p "${REMOTEPORT}" "${REMOTEUSER}"@"${REMOTESERVER}" echo test)" ]; then
    log "Failed to login to ${REMOTEUSER}@${REMOTESERVER}"
    log "Make sure that your public key is in their authorized_keys"
    exit 1
fi

# Check that remote directory exists and is writeable
if ! ssh -p "${REMOTEPORT}" "${REMOTEUSER}"@"${REMOTESERVER}" test -w "${REMOTEDIR}" ; then
    log "Failed to write to ${REMOTEDIR} on ${REMOTESERVER}"
    log "Check file permissions and that ${REMOTEDIR} is correct"
    exit 1
fi

### FINISHED CHECKS ###

### BACKUP ROUTINE ###

unset RUNNING_CONTAINERS
RUNNING_CONTAINERS=($(get_running_containers))

unset container
for container in ${RUNNING_CONTAINERS[@]}; do
    unset VOLUMES
    VOLUMES=($(get_container_volumes "${container}"))
    
    #create_dir "${LOCALDIR}"

    echo ${container}
    echo ${VOLUMES[@]}
done

### FINISHED BACKUP ROUTINE
