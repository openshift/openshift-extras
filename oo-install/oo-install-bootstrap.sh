#!/bin/sh

# Grab command-line arguments
args=("$@")

: ${TMPDIR:=/tmp}
[[ $TMPDIR != */ ]] && TMPDIR="${TMPDIR}/"

echo "Downloading oo-install package..."
#curl -L -o ${TMPDIR}openshift-extras.zip https://api.github.com/repos/nhr/openshift-extras/zipball/master

echo "Extracting oo-install to temporary directory..."
unzip -qq -o ${TMPDIR}oo-install.zip -d $TMPDIR

echo "Starting oo-install..."
RUBYLIB="${TMPDIR}oo-install/lib:${TMPDIR}oo-install/vendor/bundle"
cd ${TMPDIR}oo-install && RUBYLIB=$RUBYLIB sh -c "bin/oo-install $@"
cd -

echo "oo-install exited; removing temporary assets."
#rm -rf ${TMPDIR}oo-install*

exit
