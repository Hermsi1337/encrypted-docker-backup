#!/bin/bash

# Ensure that all possible binary paths are checked
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin

### FUNCTIONS ###

log()
{   # Provides the 'log' command to simultaneously log to
    # STDOUT and the log file with a single command
    # NOTE: Use "" rather than \n unless you want a COMPLETELY blank line (no timestamp)
    echo -e "$(date +'%Y-%m-%d_%T')" "$1" >> "${LOGFILE}"
    if [ "$2" != "noecho" ]; then
        echo -e "$1"
    fi
}

include_file ()
{   # check stated file and include if present
    FILE="$( realpath ${1} )"
    if [ ! -f "${FILE}" ]; then
        echo "${FILE} is not present. Aborting..."
        exit 1
    else
        source ${FILE}
    fi
}

require_command ()
{   # check if the needed command is present
    COMMAND="$(command -v ${1})"
    if [ -z ${COMMAND} ]; then
        echo "${1} seems not available. This script can not be executed without it."
        exit 1
    else
        echo "${COMMAND}"
    fi
}

get_running_containers ()
{   # get a list of all running containers and put the names into an array
    unset DOCKER
    DOCKER="$(require_command docker) ps"

    ${DOCKER} --format '{{.Names}}' 
}

get_container_volumes ()
{   # use ${1} as container-name and extract mounted volumes
    CONTAINER_NAME="${1}"
    unset DOCKER
    DOCKER="$(require_command docker) inspect"

    ${DOCKER} --format '{{ range .Mounts }}{{ .Source }} {{ end }}' ${CONTAINER_NAME}
}

create_dir ()
{   # use ${1} as directory and check if it is present
    DIR="${1}"
    if [ ! -d ${DIR} ]; then
        mkdir -p ${DIR}
    fi
}

backup_check ()
{   # check if source dir is available
    # use ${1} as source
    SOURCE="${1}"

	if [ ! -r ${SOURCE} ]; then
        log "${SOURCE} is not accessible. Aborting..."
        exit 1
	fi
}

backup_run ()
{   # use ${1} as destination and ${2} as backup-source 
    # return status code at the end to check if backup was successfull
    DESTINATION="${1}"
    SOURCE="${2}"
    
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

BACKUPDATE="$(date -u +%Y-%m-%d-%H%M)"
STARTTIME="$(date +%s)"
DATEDIR="${HOSTNAME}/${BACKUPDATE}"
BACKUPDIR="${LOCALDIR}${DATEDIR}"

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
if [ ! -w "$( $(require_command dirname) ${LOCALDIR} )" ]; then
    log "Parent directory of ${LOCALDIR} either doesn't exist or isn't writable"
    log "Either fix or replace the LOCALDIR setting"
    exit 1
elif [ ! -w "$( $(require_command dirname) ${TEMPDIR} )" ]; then
    log "Parent directory of ${TEMPDIR} either doesn't exist or isn't writable"
    log "Either fix or replace the TEMPDIR setting"
    exit 1
else
    create_dir ${LOCALDIR}
    create_dir ${TEMPDIR}
    create_dir ${BACKUPDIR}
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

# check if there are any containers to exclude
if [ ! ${#EXCLUDE[@]} -eq 0 ]; then
	for CONTAINER_TO_EXCLUDE in "${EXCLUDE[@]}"; do
		RUNNING_CONTAINERS=(${RUNNING_CONTAINERS[@]//*${CONTAINER_TO_EXCLUDE}*})
	done
fi

unset CONTAINER 
for CONTAINER in ${RUNNING_CONTAINERS[@]}; do
    # define new backupdir for current container
    unset BACKUPDIRCONTAINER
    BACKUPDIRCONTAINER="${BACKUPDIR}/${CONTAINER}"
    create_dir "${BACKUPDIRCONTAINER}"

	# get volumes
    unset VOLUMES
    VOLUMES=($(get_container_volumes "${CONTAINER}"))

	# stop container to avoid corrupt data
	unset DOCKER
	DOCKER="$(require_command docker) stop"
	${DOCKER} ${CONTAINER}
    if [ ! "$( ${DOCKER} ${CONTAINER} &>/dev/null && $(require_command echo) ${?} )" -eq 0 ]; then
        log "Stopping ${CONTAINER} FAILED. Skipping..."
        continue
    fi

	for BUP in ${VOLUMES[@]}; do
		# check if the volume-dir is accessible. If not, skip.
		if [ ! "$( backup_check ${BUP} && $(require_command echo) ${?} )" -eq 0 ]; then
			log "Can not access ${BUP}! Skipping..."
			continue
		fi
		
		# prepare name of tarfile
		NAME="$( $(require_command echo) ${BUP} | $(require_command sed) 's#\/#_#g' )"
		unset TARFILE
		TARFILE="${BACKUPDIRCONTAINER}/${NAME}".tgz     

		# create backup, finally
		if [ ! "$( backup_run ${TARFILE} ${BUP} && $(require_command echo) ${?} )" -eq 0 ]; then
			log "Backup of ${BUP} FAILED."
		else
			log "Backup of ${BUP} was SUCESSFULL."
		fi
	done

	# bring container up again
	unset DOCKER
    DOCKER="$(require_command docker) start"
    if [ ! "$( ${DOCKER} ${CONTAINER} &>/dev/null && $(require_command echo) ${?} )" -eq 0 ]; then
        log "Starting ${CONTAINER} FAILED."
    fi
    
done

### FINISHED BACKUP ROUTINE ###

ENDTIME=$(date +%s)
DURATION=$((ENDTIME - STARTTIME))
log "All done. Backup and transfer completed in ${DURATION} seconds\n"

if [ $(echo ${MAILRCPT}) ]; then
    log "Sending logfile via mail"
    {
        echo To: ${MAILRCPT}
        echo Subject: Backup finished for ${HOSTNAME}
        echo
        cat ${LOGFILE}
    } | ssmtp ${MAILRCPT}
    rm -f ${LOGFILE}
else
    log "No email recipient set. Won't send logifle via mail."
fi
