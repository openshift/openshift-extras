#!/bin/sh

: ${TMPDIR:=/tmp}
[[ $TMPDIR != */ ]] && TMPDIR="$TMPDIR"/

file_prefix="openshift-openshift-extras-*"
#curl -L -o ${TMPDIR}openshift-extras.zip https://api.github.com/repos/nhr/openshift-extras/zipball/master
unzip -o ${TMPDIR}oo-install.zip -d $TMPDIR

export GEM_HOME=${TMPDIR}oo-install/vendor/bundle/ruby/1.9.1
export GEM_PATH=${TMPDIR}oo-install/vendor/bundle/ruby/1.9.1
export RUBYLIB=${TMPDIR}$oo-install/lib:${TMPDIR}oo-install/vendor/bundle/ruby/1.9.1/gems/*/lib

cd ${TMPDIR}oo-install && bin/oo-install -e
cd -
#rm -rf ${TMPDIR}openshift-*

exit
