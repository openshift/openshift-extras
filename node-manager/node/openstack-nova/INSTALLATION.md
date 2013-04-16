Installation and usage
======================

This is a guide for setting up your node host snapshot for usage by
the node manager openstack-nova event handler. There are some subtle
preparations necessary to use the node host as an image and template
for further nodes.

Initial host installation
=========================

The first step, perhaps obviously, is to install an OpenShift
Enterprise node on RHEL 6. When you do, do not use an external volume
for /var/lib/openshift, or at least, do not enter it in /etc/fstab. This
will enable attaching a different volume when the image is instantiated.
Also, do not add the node to a district or otherwise incorporate it
into an existing installation.

Install this code
=================

Now install this code at the root of the host filesystem, e.g.:

  # rsync -rpzv root/* root@node.example.com:/

cloud-init
==========

cloud-init is used as the hook to configure the host after it is
instantiated from the image. Installation currently involves configuring
the EPEL and optional channels, so definitely do this after installation
(those sources can conflict with OpenShift Enterprise packages).

  # yum-config-manager --enable rhel-6-server-optional-rpms
  # wget http://mirror.pnl.gov/epel/6/i386/epel-release-6-8.noarch.rpm
  # yum localinstall -y epel-release-6-8.noarch.rpm
  # yum install -y cloud-init

Afterward, disable these so that future updates will come from the right place:

  # yum-config-manager --disable rhel-6-server-optional-rpms
  # yum-config-manager --disable epel

SELinux workaround
==================

A temporary workaround is likely necessary for
https://bugzilla.redhat.com/show_bug.cgi?id=915701 - otherwise, oo-stats
will get no gear counts and no scaling will occur.  Work around this by
installing a custom policy:

  # cat > openshift_cron.te  #copy and paste everything until the ^D
  
  module openshift_cron 1.0;
  
  require {
	type openshift_cron_t;
	class capability dac_override;
  }
  
  #============= openshift_cron_t ==============
  allow openshift_cron_t self:capability dac_override;
  
  ^D   # actually type Ctrl-D to exit cat

  # make -f /usr/share/selinux/devel/Makefile
  # semodule -i openshift_cron.pp


Other cleanup
=============

You will need to remove the record of the NIC belonging to this host,
as it will have a different one when it is instantiated:

  # rm /etc/udev/rules.d/70-persistent-net.rules

Also, disable the mcollective service - the host will need some
configuration before it is ready to join the message bus.

  # chkconfig mcollective off

Finally, assuming you are using a subscription, it is probably best
to remove it before snapshotting and re-subscribe afterward. Using
subscription-manager, that would be:

  # subscription-manager unregister

Snapshot
========

Now, the easy part - snapshot your host in OpenStack. Give the snapshot
the name expected by the broker for the node host image. Then either
shut down or rename and use your node host.

