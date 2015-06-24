#!/bin/sh

# Grab command-line arguments
cmdlnargs="$@"

clear
echo "For Origin M4 please run:"
echo "sh <(curl -s https://install.openshift.com/origin-m4)"
echo
echo "For OpenShift Enterprise 3 run:"
echo "sh <(curl -s https://install.openshift.com/ose)"
echo
echo "An Origin oo-install script for the latest code is still being developed."
echo "See https://github.com/openshift/origin/blob/master/README.md#getting-started"
echo "for details on how to run the latest code from a Docker container."
echo
