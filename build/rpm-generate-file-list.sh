#!/bin/bash
set -u
#set -x

SOURCE_PACKAGES=${1:-/opt/odie/src/conf/base-rpms.txt}
PARENT_MANIFEST=${2:-/dev/null}
PARENT_PACKAGES=${3:-/dev/null}


OUTPUT_DIR=${ROOT_DIR:-/opt/odie/src/output/}
LOG_DIR=${ROOT_DIR:-/opt/odie/src/manifests/}

PACKAGES=$(basename ${SOURCE_PACKAGES})
TARGET_PACKAGES=${TARGET_PACKAGES:-${LOG_DIR}/${PACKAGES}.packages}
PROCESSED_FILE=${PROCESSED_FILE:-${LOG_DIR}/${PACKAGES}.processed}
QUEUE_FILE=${QUEUE_FILE:-${LOG_DIR}/${PACKAGES}.queue}
ERROR_FILE=${ERROR_FILE:-${LOG_DIR}/${PACKAGES}.error}
MANIFEST_FILE=${PROCESSED_FILE:-${PACKAGES}.manifest}

# force this to start the while loop
export COUNT=1

# The main issue is with yum having an exclusive lock on the yum db
# After some testing I determined that >3 threads you end up just having a lot of idle
# threads since everyone is waiting on the lock
THREADS=${THREADS:-4}

########### END CONFIGURATION ####################

function check_dep() {
  NAME=$1

  # Before we proceed a quick rant -- yum deplist is hot garbage
  # There is no way to specify architecture (so it will randomly pick i686
  # packages on occasionally.  Also, it fails silently if the package is not found.
  # so we have to manually parse the log output
  # STDERR is suppressed since you get nagged about the lock all the times
  DEPLIST=$( sudo yum -C deplist $NAME  2>/dev/null )

  # try the package name as is (probably noarch or explicit version)
  if [[ $(echo "$DEPLIST" | wc -l) = 2 ]] ; then
    return 1
  else
    return 0
  fi
}


function sort_files() {
  sort -u $QUEUE_FILE -o $QUEUE_FILE
  sort -u $TARGET_PACKAGES -o $TARGET_PACKAGES
  sort -u $ERROR_FILE -o $ERROR_FILE
  cat $ERROR_FILE >> $PROCESSED_FILE
  sort -u $PROCESSED_FILE -o $PROCESSED_FILE

}

function count() {
  sort_files
  PACKAGES=$(cat $TARGET_PACKAGES | sort -u | comm -1 -3 - $QUEUE_FILE| comm -3 - ${ERROR_FILE} )
  COUNT=$(echo $PACKAGES | wc -w )

  echo "$(date) - Packages remaining to parse $COUNT "

  if [[ $COUNT = 0  ]]; then
    return 1
  else
    return 0
  fi

}

function process_file() {
  #SOURCE_PACKAGES=$1
  PACKAGES=$(cat $TARGET_PACKAGES | sort -u | comm -1 -3 - $QUEUE_FILE | comm -3 - ${ERROR_FILE} | head -${THREADS})

  for package in $(echo ${PACKAGES}) ; do
    parse_package "$package" &
  done

  wait

}


function parse_package() {
  PACKAGE=$1
  echo "Processing $PACKAGE"

  export DEPLIST=""

  # To mitigate this loop below will first attempt the package with .x86_64 appended,
  # If the output is empty (2 lines), then we try .noarch
  # then we give up on that package

  check_dep $PACKAGE.x86_64

  if [[ $? = 1 ]]; then
    check_dep $PACKAGE
  fi

  if [[ $? = 1 ]]; then
      (>&2 echo "WARNING: No information found for $PACKAGE")
      echo $PACKAGE >> $ERROR_FILE
      continue
  fi

  PACKAGE_NAME_REGEXP="perl -pe 's/^.*: //; s/(.\w+) (.*)$/-\2\1/;'"

  # queue file is a listing of package names, while the manifest contains the fully qualified version
  #echo "$DEPLIST" | egrep 'provider:|package:' | grep -v 'i686' |  $PACKAGE_NAME_REGEXP \
  #  | tee -a $MANIFEST_FILE | perl -pe 's/(.*?)\-\d+\.el7.*?\.(x86_64|noarch)$//;' >> $QUEUE_FILE

    echo "$PACKAGE" >> $TARGET_PACKAGES
    echo "$DEPLIST"  | egrep 'package:' |  perl -pe 's/^.*: //; s/(.\w+) (.*)$/-\2\1/;' >> $PROCESSED_FILE
    echo "$DEPLIST" | egrep 'provider:' | egrep -v 'i686|\.el7' |  perl -pe 's/^.*: //; s/(.\w+) (.*)$/-\2\1/;' |   perl -pe 's/(.*?)\-\d+\.el7.*?\.(x86_64|noarch)$//;' >> $MANIFEST_FILE

    echo "$DEPLIST" | egrep 'provider:' | egrep -v 'i686' |   perl -pe 's/^.*: //;s/^(.*?) .*?$/\1/;s/\.noarch//; s/\.x86_64//;'  >> $QUEUE_FILE
    #echo "$DEPLIST" | egrep 'provider:' | egrep -v 'i686' | >> $QUEUE_FILE #perl -pe 's/^.*: //; s/(.\w+) (.*)$/-\2\1/;' >>  $QUEUE_FILE
}


handler()
{
  echo "Caught SIGINT.  Waiting for yum to finish before exiting.."
  wait
  sort_files
  exit 2
}

trap handler SIGINT

# prep these files
mkdir -p $LOG_DIR
mkdir -p $OUTPUT_DIR

#cp $SOURCE_PACKAGES $TARGET_PACKAGES
touch $QUEUE_FILE $ERROR_FILE $PROCESSED_FILE $TARGET_PACKAGES

# these files were completed by the base RPM set and can be ignored
# the script will return a manifest containing just the child dependencies

cat ${PARENT_MANIFEST} >> $PROCESSED_FILE
sort_files

#cat ${TARGET_PACKAGES} >> $QUEUE_FILE
sort -u $SOURCE_PACKAGES | comm -2 -3 - $PARENT_PACKAGES >> $QUEUE_FILE

while [ $COUNT != 0 ]; do
  count
  time process_file
  echo
done

