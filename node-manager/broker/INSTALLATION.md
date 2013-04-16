Installation and usage
======================

On OpenShift Enterprise broker, copy the files under this directory, e.g.:

  # rsync -rpzv root/* root@broker.example.com:/

Configure /etc/openshift/nodemgr/capacity.conf as well as the required
configuration files for your chosen event handler if necessary.

Then, start the service:

  # chkconfig openshift-nodemgr on
  # service openshift-nodemgr start

Logs
====

The openshift-nodemgr service logs to:
/var/log/openshift/broker/openshift-nodemgr.log

Event handlers are expected to log somewhere under the same directory.

