#!/bin/sh

# Grab command-line arguments
args=("$@")

: ${TMPDIR:=/tmp}
[[ $TMPDIR != */ ]] && TMPDIR="${TMPDIR}/"

echo "Downloading oo-install package..."
curl -o ${TMPDIR}oo-install.zip http://oo-install.rhcloud.com/oo-install.zip

echo "Extracting oo-install to temporary directory..."
unzip -qq -o ${TMPDIR}oo-install.zip -d $TMPDIR

echo "Starting oo-install..."
RUBYLIB="${TMPDIR}oo-install/lib:${TMPDIR}oo-install/vendor/bundle"
cd ${TMPDIR}oo-install && RUBYLIB=$RUBYLIB sh -c "bin/oo-install $@"
cd -

echo "oo-install exited; removing temporary assets."
rm -rf ${TMPDIR}oo-install*

exit
