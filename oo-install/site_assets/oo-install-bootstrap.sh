#!/bin/sh

# Grab command-line arguments
cmdlnargs="$@"

: ${OO_INSTALL_KEEP_ASSETS:="false"}
: ${OO_INSTALL_CONTEXT:="INSTALLCONTEXT"}
: ${TMPDIR:=/tmp}
[[ $TMPDIR != */ ]] && TMPDIR="${TMPDIR}/"

if [ $OO_INSTALL_CONTEXT != 'origin_vm' ]
then
  echo "Checking for necessary tools..."
fi
for i in ruby unzip ssh
do
  command -v $i >/dev/null 2>&1 || { echo >&2 "OpenShift installation requires $i but it does not appear to be available. Correct this and rerun the installer."; exit 1; }
done
if [ $OO_INSTALL_CONTEXT != 'origin_vm' ]
then
  echo "...looks good."
fi

# All instances of INSTALLPKGNAME are replaced during packaging with the actual package name.
if [[ -e ./INSTALLPKGNAME.zip ]]
then
  if [ $OO_INSTALL_CONTEXT != 'origin_vm' ]
  then
    echo "Using bundled assets."
  fi
  cp INSTALLPKGNAME.zip ${TMPDIR}/INSTALLPKGNAME.zip
elif [[ $OO_INSTALL_KEEP_ASSETS == 'true' && -e ${TMPDIR}/INSTALLPKGNAME.zip ]]
then
  if [ $OO_INSTALL_CONTEXT != 'origin_vm' ]
  then
    echo "Using existing installer assets."
  fi
else
  echo "Downloading oo-install package..."
  curl -s -o ${TMPDIR}INSTALLPKGNAME.zip https://install.openshift.com/INSTALLVERPATHINSTALLPKGNAME.zip
fi

if [ $OO_INSTALL_CONTEXT != 'origin_vm' ]
then
  echo "Extracting oo-install to temporary directory..."
fi
unzip -qq -o ${TMPDIR}INSTALLPKGNAME.zip -d $TMPDIR

if [ $OO_INSTALL_CONTEXT != 'origin_vm' ]
then
  echo "Starting oo-install..."
else
  clear
fi
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

if [ $OO_INSTALL_CONTEXT != 'origin_vm' ]
then
  if [ $OO_INSTALL_KEEP_ASSETS == 'true' ]
  then
    echo "oo-install exited; keeping temporary assets in ${TMPDIR}"
  else
    echo "oo-install exited; removing temporary assets."
    rm -rf ${TMPDIR}INSTALLPKGNAME*
  fi
fi

exit
