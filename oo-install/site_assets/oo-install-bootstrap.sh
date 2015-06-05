#!/bin/sh

# Grab command-line arguments
cmdlnargs="$@"

: ${OO_INSTALL_KEEP_ASSETS:="false"}
: ${OO_INSTALL_CONTEXT:="INSTALLCONTEXT"}
: ${TMPDIR:=/tmp}
: ${OO_INSTALL_LOG:=${TMPDIR}/INSTALLPKGNAME.log}
[[ $TMPDIR != */ ]] && TMPDIR="${TMPDIR}/"

if [ $OO_INSTALL_CONTEXT != 'origin_vm' ]
then
  echo "Checking for necessary tools..."
fi
for i in python ssh
do
  command -v $i >/dev/null 2>&1 || { echo >&2 "OpenShift installation requires $i but it does not appear to be available. Correct this and rerun the installer."; exit 1; }
done
if [ $OO_INSTALL_CONTEXT != 'origin_vm' ]
then
  echo "...looks good."
fi

# All instances of INSTALLPKGNAME are replaced during packaging with the actual package name.
if [[ -e ./INSTALLPKGNAME.tgz ]]
then
  if [ $OO_INSTALL_CONTEXT != 'origin_vm' ]
  then
    echo "Using bundled assets."
  fi
  cp INSTALLPKGNAME.tgz ${TMPDIR}/INSTALLPKGNAME.tgz
elif [[ $OO_INSTALL_KEEP_ASSETS == 'true' && -e ${TMPDIR}/INSTALLPKGNAME.tgz ]]
then
  if [ $OO_INSTALL_CONTEXT != 'origin_vm' ]
  then
    echo "Using existing installer assets."
  fi
else
  echo "Downloading oo-install package..."
  curl -s -o ${TMPDIR}INSTALLPKGNAME.tgz https://install.openshift.com/INSTALLVERPATHINSTALLPKGNAME.tgz
fi

if [ $OO_INSTALL_CONTEXT != 'origin_vm' ]
then
  echo "Extracting oo-install to temporary directory..."
fi
tar xzf ${TMPDIR}INSTALLPKGNAME.tgz -C ${TMPDIR}

if [ $OO_INSTALL_CONTEXT != 'origin_vm' ]
then
  echo "Starting oo-install..."
else
  clear
fi

echo "Hello, OpenShift..."

cd ${TMPDIR}/INSTALLPKGNAME
source ./bin/activate
echo "Preparing to install.  This can take a minute or two..."
pip install --no-index -f file:///$(readlink -f deps) ansible 2>&1 > $OO_INSTALL_LOG
virtualenv --relocatable .
echo "Done!"

ansible --version

if [ $OO_INSTALL_KEEP_ASSETS == 'true' ]
then
  echo "oo-install exited; keeping temporary assets in ${TMPDIR}"
else
  echo "oo-install exited; removing temporary assets."
  rm -rf ${TMPDIR}INSTALLPKGNAME*
fi

exit
