#!/bin/sh

# Grab command-line arguments
cmdlnargs="$@"

: ${OO_INSTALL_KEEP_ASSETS:="false"}
: ${TMPDIR:=/tmp}
[[ $TMPDIR != */ ]] && TMPDIR="${TMPDIR}/"

echo "Checking for necessary tools..."
for i in ruby ssh
do
  command -v $i >/dev/null 2>&1 || { echo >&2 "OpenShift installation requires $i but it does not appear to be available. Correct this and rerun the installer."; exit 1; }
done
echo "...looks good."

# All instances of INSTALLPKGNAME are replaced during packaging with the actual package name.
if [[ -e ./INSTALLPKGNAME.tgz ]]
then
  echo "Using bundled assets."
  cp INSTALLPKGNAME.tgz ${TMPDIR}/INSTALLPKGNAME.tgz
elif [[ $OO_INSTALL_KEEP_ASSETS == 'true' && -e ${TMPDIR}/INSTALLPKGNAME.tgz ]]
then
  echo "Using existing installer assets."
else
  echo "Downloading oo-install package..."
  curl -s -o ${TMPDIR}INSTALLPKGNAME.tgz https://install.openshift.com/INSTALLVERPATHINSTALLPKGNAME.tgz
fi

echo "Extracting oo-install to temporary directory..."
tar xzf ${TMPDIR}INSTALLPKGNAME.tgz -C $TMPDIR

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
GEM_PATH=$GEMPATH RUBYLIB=$RUBYLIB OO_INSTALL_CONTEXT=INSTALLCONTEXT OO_INSTALL_VERSION='INSTALLVERSION' sh -c "${TMPDIR}INSTALLPKGNAME/bin/oo-install ${cmdlnargs}"

if [ $OO_INSTALL_KEEP_ASSETS == 'true' ]
then
  echo "oo-install exited; keeping temporary assets in ${TMPDIR}"
else
  echo "oo-install exited; removing temporary assets."
  rm -rf ${TMPDIR}INSTALLPKGNAME*
fi

exit
