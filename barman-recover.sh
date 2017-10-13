#!/usr/bin/env bash

: <<LICENSE
    Copyright (C) 2016-2017, Finalsite
    Author: Darryl Wisneski <darryl.wisneski@finalsite.com>
    Author: Carl Corliss <carl.corliss@finalsite.com>

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.

LICENSE

PROGRAM="$(/bin/basename "$0")"
REVISION="0.8.0"

STATE_OK=0
STATE_CRITICAL=2
STATE_UNKNOWN=3

declare -a OPTIONS
OPTIONS=()

DATE="$(date +%Y%m%d)"
AUTO_RECOVERY_PATH="/var/lib/barman/auto_recovery"
MANUAL_RECOVERY_PATH="/var/lib/barman/recovery"
DEFAULT_PG_VERSION="$(psql --version | grep --color=no -oP '\s+\K\d+\.\d+')"
AUTO_RECOVERY_PORT="5433"
AUTO_RECOVERY_APPNAME="composer"
BARMAN_LOG="/tmp/pitr-recovery.log"
RECOVERY_LOG="/tmp/recover.log"

revision_details() {
  echo "$1 v$2"
  return 0
}

usage() {
    cat <<EOF
 Usage:
    ${PROGRAM} [options]

Options:
    -a --app-name          Barman server/app name (default: ${AUTO_RECOVERY_APPNAME})
    -b --backup-name       Barman backup name to recover
    -d --debug             Debug mode
    -h --help              Show usage information and exit
    -m --manual            Manual mode (default recovery path: ${MANUAL_RECOVERY_PATH})
    -p --port              Listen port for PG recovery DB (default: ${AUTO_RECOVERY_PORT})
    -P --pg-version        Postgresql major version (default: dynamically lookup current version)
    -l --list-backups      List barman backups
    -r --auto              Automated mode (default: ${AUTO_RECOVERY_PATH})
    -n --target-name       Target name, use with pg_create_restore_point()
    -t --target-tli        Target timeline to recovery to
    -T --target-time       Target time to recovery to (YYYYMMDDHHMMSS)
    -v --verbose           Verbose output
    -V --version           Show version and exit
    -x --target-xid        Target transaction ID to recovery to

EOF
    return 0
}

verbose() {
  ((VERBOSE >= 1)) && echo "$@"
}

debug() {
  ((DEBUG >= 1)) && echo "$@"
}

error() {
  echo "Error: $@" >&2
}

exit_with_error() {
  local code=$1; shift
  [[ $# -ge 1 ]] && error "$@"
  exit ${code}
}

show_help() {
    revision_details "${PROGRAM}" "${REVISION}"
    usage
cat <<DESC
    Recovery helper tool for pgbarman PITR
    Recover a postgresql PITR automatically or manually with a single command

Examples:
    Automated recovery:
      /usr/local/bin/barman-recover -r
    Get the list of available backups:
      /usr/local/bin/barman-recover -l
    Recover barman server: example, recover the _20170918T000101_ backup, fire up the postgresql recovery DB on port 5555, recover to time 20170919, at 12:01:00:
      /usr/local/bin/barman-recover -mv -a composer -b 20170918T000101 -p 5555 -T '2017-09-19 12:01:00 EST'
DESC
    return 0
}

stop_postgres() {
  debug "Function: ${FUNCNAME}"
  if [[ ! -f "${RECOVERY_PATH}/postmaster.pid" ]]; then
    verbose "Unable to find PID file for PostgreSQL in ${RECOVERY_PATH}"
    return 1
  fi
  local PID=$(head -n1 "${RECOVERY_PATH}"/postmaster.pid)
  debug "PID: ${PID}"
  #kill -0 returns true if the process is found
  if kill -0 ${PID} &>/dev/null; then
    debug "PID: ${PID} found running"
    if ${PG_CTL} -D "${RECOVERY_PATH}" -mfast stop &>/dev/null; then
      verbose "stopping PostgreSQL for pid: ${PID} with RECOVERY_PATH: ${RECOVERY_PATH}"
    else
      exit_with_error "${STATE_CRITICAL}" "RECOVERY_PATH: ${RECOVERY_PATH} could not be deleted"
    fi
  else
    verbose "No running PostgreSQL found for pid: ${PID}, continuing..."
  fi

}

kill_postgres() {
  debug "Function: ${FUNCNAME}"
  # found no pid file, attempt to kill PostgreSQL running with
  # current ${RECOVERY_PATH}, by getting PID, then sigTERM
  local PID=$(pgrep -u barman -f "postgres.+${RECOVERY_PATH}")
  if [[ ${PID} -gt 0 ]]; then
    verbose "PID of PostgreSQL to kill: ${GPID}"
    if kill -TERM "${PID}" &>/dev/null; then
      exit_with_error ${STATE_CRITICAL} "can't stop PostgreSQL with datadir "${RECOVERY_PATH}" and pid: ${PID}"
    else
      verbose "killed PostgreSQL with datadir "${RECOVERY_PATH}" and pid: ${PID}"
    fi
  else
    verbose "PostgreSQL is not running with datadir: ${RECOVERY_PATH}, continuing"
  fi
}

stop_recovery() {
  stop_postgres || kill_postgres
}

delete_recovery() {
  debug "Function: ${FUNCNAME}"
  if [[ -d ${RECOVERY_PATH} && ${RECOVERY_PATH} != / ]]; then
    if /bin/rm -rf "${RECOVERY_PATH}" &>/dev/null; then
      verbose "RECOVERY_PATH: ${RECOVERY_PATH} deleted"
    else
      exit_with_error ${STATE_CRITICAL} "RECOVERY_PATH: ${RECOVERY_PATH} could not be deleted"
    fi
  fi
}

list_backup() {
  debug "Function: ${FUNCNAME}"
  get_options
  barman list-backup --minimal "${RECOVERY_APPNAME}"
  local EXITCODE=$?
  if (( "${EXITCODE}" != 0 )) ; then
    exit_with_error ${STATE_CRITICAL} "barman list-backup failed with exit code: ${EXITCODE}"
  fi
}

get_latest_backup_name() {
  debug "Function: ${FUNCNAME}"
  # pick the top backup name
  LATEST_BACKUP=$(barman list-backup --minimal "${AUTO_RECOVERY_APPNAME}" |head -n1; exit ${PIPESTATUS[0]})
  local EXITCODE=$?
  debug "Latest_Backup: ${LATEST_BACKUP}"
  # exit immediately if we failed our test
  [[ "${EXITCODE}" -gt 0 ]] && exit_with_error "${EXITCODE}" \
    "did not retrieve latest backup from barman, received ${LATEST_BACKUP}"

  verbose "LATEST_BACKUP: ${LATEST_BACKUP}"
  verbose "AUTO_RECOVERY_APPNAME: ${AUTO_RECOVERY_APPNAME}"
  RECOVERY_BACKUP_NAME="${LATEST_BACKUP}"
}

start_barman_recovery() {
  debug "Function ${FUNCNAME}"
  if [[ ! -d "${RECOVERY_PATH}" ]]; then
    mkdir -p "${RECOVERY_PATH}"
  fi

  if [[ ${#OPTIONS[@]} -ge 1 ]]; then
    barman recover "${OPTIONS[@]}" > ${BARMAN_LOG} 2>&1
    local EXITCODE=$?
    if [[ ${EXITCODE} -gt 0 ]]; then
      exit_with_error "${EXITCODE}" "barman recover: ${OPTIONS[@]}"
    fi
  else
    exit_with_error ${STATE_CRITICAL} "Error in OPTIONS value(S): ${OPTIONS[@]}"
  fi
}

modify_recovery_config() {
  debug "Function: ${FUNCNAME}"
  debug "RECOVERY_PORT: ${RECOVERY_PORT}"

  awk "
    # ignore unix_socket_directories, and just append the updated version
    # to the end of the file (see END section below)
    /^\s*unix_socket_directories\s*=/ { next }

    # skip log_directory - it_s not needed for recovery
    /^\s*log_directory\s*=/ { next }

    # perform various substitutions
    {
      # general substitutions
      gsub(/^\s*port\s*=.+/, \"port = '${RECOVERY_PORT}'\");
      gsub(/^\s*data_directory\s*=.+/, \"data_directory = '${RECOVERY_PATH}'\")
      a[b++]=\$0
    }

    # now output the buffered data to the file
    END {
      for (c=0; c <= b; c++) {
        # output each line to the file specified in ARGV[1]
        print a[c] > ARGV[1]
      }
      # now append unix_socket_directories using the value we want for recovery
      print \"unix_socket_directories = '/tmp'\" > ARGV[1]
    }
  " ${RECOVERY_PATH}/postgresql.conf

  [[ "$?" == 0 ]] || exit_with_error ${STATE_CRITICAL} \
                     "failed to munge postgresql.conf with OPTIONS: ${RECOVERY_PATH} and ${RECOVERY_PORT}"
}

start_recovery_db() {
  debug "Function: ${FUNCNAME}"
  "${PG_CTL}" -D "${RECOVERY_PATH}" start &> ${RECOVERY_LOG}
  local EXITCODE=$?

  timeout=10
  while ! pgrep -U barman -f 'postgres.+auto_recovery' &>-; do
    timeout=$((timeout - 1))
    (( timeout <= 0 )) && break
    sleep 1
  done

  if grep FATAL "${RECOVERY_LOG}"; then
    exit_with_error ${STATE_CRITICAL} "PostgreSQL failed to start with message: $(cat "${RECOVERY_LOG}")"
  fi

  if [[ ${EXITCODE} -lt 1 ]]; then
    shopt -s nocaseglob
    case "${RECOVERY_MODE}" in
      manual)
      echo "PostgreSQL is running on port: ${RECOVERY_PORT}, in datadir: ${RECOVERY_PATH}"
      echo
      echo "stop the database (as barman) with '"${PG_CTL}" -D "${RECOVERY_PATH}" -mfast stop'"
      ;;
      auto) verbose "PostgreSQL is recovered in automatic mode"
      ;;
      *) exit_with_error ${STATE_UNKNOWN} "unknown recovery_mode ${RECOVERY_MODE}"
      ;;
    esac
    shopt -u nocaseglob
  else
    exit_with_error ${STATE_CRITICAL} "PostgreSQL failed to start with exit code: ${EXITCODE}"
  fi
}

get_options() {
  debug "Function: ${FUNCNAME}"

  PG_VERSION=${PG_VERSION:-${DEFAULT_PG_VERSION}}

  PG_CTL="/usr/pgsql-${PG_VERSION}/bin/pg_ctl"
  if [[ ! -f "${PG_CTL}" ]]; then
    exit_with_error ${STATE_UNKNOWN} "pg_ctl could not be found at ${PG_CTL}, using PG_VERSION: ${PG_VERSION}"
  elif [[ ! -x "${PG_CTL}" ]]; then
    exit_with_error ${STATE_UNKNOWN} "${PG_CTL} is not executable by ${USER}"
  fi

  case "${RECOVERY_MODE}" in
    auto)
      RECOVERY_APPNAME=${AUTO_RECOVERY_APPNAME}
      RECOVERY_PATH=${AUTO_RECOVERY_PATH}
      RECOVERY_PORT="${RECOVERY_PORT:-${AUTO_RECOVERY_PORT}}"
      OPTIONS=(${RECOVERY_APPNAME} ${RECOVERY_BACKUP_NAME} "${RECOVERY_PATH}")
      ;;
    manual)
      RECOVERY_APPNAME="${APPNAME}"
      RECOVERY_BACKUP_NAME="${BACKUP_NAME}"
      RECOVERY_PATH="${MANUAL_RECOVERY_PATH}/${RECOVERY_BACKUP_NAME}"
      OPTIONS=(${RECOVERY_APPNAME} ${RECOVERY_BACKUP_NAME} "${RECOVERY_PATH}")

      if [[ -n "${RECOVERY_TARGET_NAME}" ]]; then
        OPTIONS+=(--target-name ${RECOVERY_TARGET_NAME})
      elif [[ -n "${RECOVERY_TARGET_TLI}" ]]; then
        OPTIONS+=(--target-tli ${RECOVERY_TARGET_TLI})
      elif [[ -n "${RECOVERY_TARGET_TIME}" ]]; then
        OPTIONS+=(--target-time "${RECOVERY_TARGET_TIME}")
      elif [[ -n "${RECOVERY_TARGET_XID}" ]]; then
        OPTIONS+=(--target-xid ${RECOVERY_TARGET_XID})
      fi
      ;;
    list)
      if [[ "${APPNAME}" != "" ]]; then
        RECOVERY_APPNAME=${APPNAME}
      else
        RECOVERY_APPNAME=${AUTO_RECOVERY_APPNAME}
      fi
      ;;
    *)
      exit_with_error ${STATE_CRITICAL} "Error: bad RECOVERY_MODE: ${RECOVERY_MODE}"
      ;;
  esac

  debug "RECOVERY_APPNAME:     ${RECOVERY_APPNAME}"
  debug "RECOVERY_BACKUP_NAME: ${RECOVERY_BACKUP_NAME}"
  debug "RECOVERY_PATH:        ${RECOVERY_PATH}"
  debug "OPTIONS:              ${OPTIONS[@]}"
}

recover() {
  if [[ $# -ne 1 ]]; then
    exit_with_error ${STATE_UNKNOWN} "recover(): Expected 1 argument but found 0."
  elif [[ ! "$*" =~ (auto(mated)?|manual) ]]; then
    exit_with_error ${STATE_UNKNOWN} "recover(): Expected argument to be one of 'automated' or 'manual', but found '$*'"
  fi

  debug "Function: ${FUNCNAME}"
  [[ "$*" =~ auto(mated)? ]] && get_latest_backup_name
  get_options
  stop_recovery
  delete_recovery
  start_barman_recovery
  modify_recovery_config
  start_recovery_db
}

EXITCODE=${STATE_OK} #default
DEBUG=0
VERBOSE=0
[[ $# -lt 1 ]] && show_help && exit ${STATE_UNKNOWN}

OPTS=$(getopt --name "${PROGRAM}" -o a:b:n:p:P:t:T:x:b:vdrmlhV -l appname:,backup-name:,port:,pg-version:,target-name:,target-tli:,target-time:,target-xid:,verbose,debug,auto,manual,list-backup,help,version -- "$@")
[[ $? -ne 0 ]] && exit 1
eval set -- "${OPTS}"

while true; do
  case "$1" in
    --help|-h)         show_help; exit $STATE_OK;;
    --version|-V)      revision_details "${PROGRAM}" "${REVISION}"; exit $STATE_OK;;
    --verbose|-v)      VERBOSE="$((${VERBOSE} + 1))"; shift 1;;
    --debug|-d)        DEBUG="$((${DEBUG} + 1))"; shift 1;;
    --list-backup|-l)  RECOVERY_MODE=list; shift 1;;
    --auto|--automated|--robot|-r)
                       RECOVERY_MODE=auto; shift 1;;
    --manual|-m)       RECOVERY_MODE=manual; shift 1;;
    --port|-p)         RECOVERY_PORT=$2; shift 2;;
    --pg-version|-P)   PG_VERSION=$2; shift 2;;
    --appname|-a)      APPNAME=$2; shift 2;;
    --target-name|-n)  RECOVERY_TARGET_NAME=$2; shift 2;;
    --target-tli|-t)   RECOVERY_TARGET_TLI=$2; shift 2;;
    --target-time|-T)  RECOVERY_TARGET_TIME=$2; shift 2;;
    --target-xid|-x)   RECOVERY_TARGET_XID=$2; shift 2;;
    --backup-name|-b)  BACKUP_NAME=$2; shift 2;;
    --) shift; break;;
    *) echo "Unknown argument: $1" && usage && exit $STATE_UNKNOWN;;
  esac
done

case "${RECOVERY_MODE}" in
  auto)   recover automated;;
  manual) recover manual;;
  list)   list_backup;;
esac

exit $EXITCODE
