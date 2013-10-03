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
RUBYDIR='1.9.1'
RUBYVER=`ruby -v`
if [[ $RUBYVER == ruby\ 1\.8* ]]
then
  RUBYDIR='1.8'
fi
GEM_PATH="${TMPDIR}oo-install/vendor/bundle/ruby/${RUBYDIR}/gems/"
RUBYLIB="${TMPDIR}oo-install/lib:${TMPDIR}oo-install/vendor/bundle"
for i in `ls $GEM_PATH`
do
  RUBYLIB="${RUBYLIB}:${GEM_PATH}${i}/lib/"
done
GEM_PATH=$GEMPATH RUBYLIB=$RUBYLIB sh -c "${TMPDIR}oo-install/bin/oo-install $@"

echo "oo-install exited; removing temporary assets."
rm -rf ${TMPDIR}oo-install*

exit
