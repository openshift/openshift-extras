#!/bin/sh

# Grab command-line arguments
args=("$@")

: ${OO_INSTALL_KEEP_ASSETS:="false"}
: ${TMPDIR:=/tmp}
[[ $TMPDIR != */ ]] && TMPDIR="${TMPDIR}/"

echo "Checking for necessary tools..."
for i in ruby unzip ssh
do
  command -v $i >/dev/null 2>&1 || { echo >&2 "OpenShift installation requires $i but it does not appear to be available. Correct this and rerun the installer."; exit 1; }
done
echo "...looks good."

# All instances of INSTALLPKGNAME are replaced during packaging with the actual package name.
if [ $OO_INSTALL_KEEP_ASSETS == 'true' ] && [ -e ${TMPDIR}/INSTALLPKGNAME.zip ]
then
  echo "Reusing existing installer assets."
else
  echo "Downloading oo-install package..."
  curl -o ${TMPDIR}INSTALLPKGNAME.zip http://oo-install.rhcloud.com/INSTALLPKGNAME.zip
fi

echo "Extracting oo-install to temporary directory..."
unzip -qq -o ${TMPDIR}INSTALLPKGNAME.zip -d $TMPDIR

echo "Starting oo-install..."
RUBYDIR='1.9.1'
RUBYVER=`ruby -v`
if [[ $RUBYVER == ruby\ 1\.8* ]]
then
  RUBYDIR='1.8'
fi
GEM_PATH="${TMPDIR}INSTALLPKGNAME/vendor/bundle/ruby/${RUBYDIR}/gems/"
RUBYLIB="${TMPDIR}INSTALLPKGNAME/lib:${TMPDIR}oo-install/vendor/bundle"
for i in `ls $GEM_PATH`
do
  RUBYLIB="${RUBYLIB}:${GEM_PATH}${i}/lib/"
done
GEM_PATH=$GEMPATH RUBYLIB=$RUBYLIB sh -c "${TMPDIR}INSTALLPKGNAME/bin/oo-install $@"

if [ $OO_INSTALL_KEEP_ASSETS == 'true' ]
then
  echo "oo-install exited; keeping temporary assets in ${TMPDIR}"
else
  echo "oo-install exited; removing temporary assets."
  rm -rf ${TMPDIR}INSTALLPKGNAME*
fi

exit
