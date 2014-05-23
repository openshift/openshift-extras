#!/bin/bash
set -e

GEAR_DIR="/var/lib/openshift/"

update_file() {
  local file=$1
  local pattern=$2
  local replace=$3
  local unless=$4

  if grep -q -s ${unless} ${file}; then
    echo "    ${file} appears to be updated already."
  else
    echo "    Updating ${file}."
    sed -i.bak -e "s/${pattern}/${replace}/g" ${file}
  fi
}

MATCHES=$(find ${GEAR_DIR} -maxdepth 2 -name ruby -type d 2>&1)
if [ -z "${MATCHES}" ]; then
  echo "No ruby gears found."
else
  for m in $MATCHES; do
    geardir=${m%/ruby}
    gear=${geardir#${GEAR_DIR}}
    echo "Updating Gear: $gear"
    echo "================================================================================"

    for file in bin/setup lib/util lib/ruby_context; do
      # Update bin/setup
      update_file ${geardir}/ruby/${file} "scl enable ruby193" "scl enable ruby193 v8314" "v8314"
    done


    echo -e "\n\n"
  done
fi

