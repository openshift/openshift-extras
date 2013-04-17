Automating node scaling via OpenStack and the nova client
=========================================================

To have an OpenShift installation automate the creation of new node
hosts in order to increase capacity, it needs the following:

1. A method of detecting when and where it needs a new node host.
2. A node host image that OpenStack can instantiate.
3. The means to request and configure a new node host from the image.

The node manager implements the logic for determining when to scale
(see [README.md](README.md)).

The openstack-nova event handler uses the OpenStack nova client and
native API to control resources. Currently only the "create-node" event
is implemented.

It is necessary for an admin to create a node host image and allow node
hosts to be named according to the scheme in this handler:

* You need to snapshot your node host before it has any gears and
  before it has been placed in a district. The name (in OpenStack)
  must be exactly as specified in node.conf.
* New hosts will be named the base name specified in node.conf
  followed by a separator and number. In OpenStack the separator
  is an underscore, while the actual host name uses a hyphen as a
  separator; so a default first node would be named openshift-node_1
  in OpenStack and have the hostname openshift-node-1.example.com.

Some other assumptions:

* Use of districts is assumed.
* This implementation creates and configures an external volume
  via OpenStack to be used as storage for the gears directory
  (`/var/lib/openshift`). The volume is given the same name as the host.
* The volume is assumed to be `/dev/vdc` - if it is anything else,
  modify the node image `reinit-node` script.
* It is assumed that DNS for the node hosts can be added in the
  same domain as apps.

Preparing the node base image
=============================

As mentioned, an admin must create a node host image to be the
basis for future node hosts.  This requires a number of steps
to be performed for proper use of the image. Please consult
[node/openstack-nova/INSTALLATION.md](node/openstack-nova/INSTALLATION.md) for directions.

Broker configuration
====================

In addition to copying the broker code onto a completed broker
installation (as described in [broker/INSTALLATION.md](broker/INSTALLATION.md)):

    # rsync -rpzv broker/root/* root@broker.example.com:/

Also install the nova client. This requires enabling Optional and EPEL,
so do this after the OpenShift Enterprise broker installation.

    # yum-config-manager --enable rhel-6-server-optional-rpms
    # wget http://mirror.pnl.gov/epel/6/i386/epel-release-6-8.noarch.rpm
    # yum localinstall -y epel-release-6-8.noarch.rpm
    # yum install -y python-pip
    # pip-python install python-novaclient

Disable the extra repositories to avoid conflicts with future
OpenShift Enterprise updates:

    # yum-config-manager --disable rhel-6-server-optional-rpms
    # yum-config-manager --disable epel

Download your OpenStack API credentials from the OpenStack web UI and
transfer these over to `/etc/openshift/nodemgr/openstack-nova/auth.env`
Make sure the credentials are not prompting for a password. Test them
as follows:

    # . /etc/openshift/nodemgr/openstack-nova/auth.env
    # nova credentials

Finally, make sure to configure "openstack-nova" as the handler
in `/etc/openshift/nodemgr/capacity.conf` and edit
`/etc/openshift/nodemgr/openstack-nova/node.conf` to your satisfaction.

Once all is ready, start the service with:

    # service openshift-nodemgr start

Known issues
============

* The mcollective calls made by oo-stats seem to have a tendency to
  hang inexplicably, either recovering eventually or raising an error,
  especially around the time of nodes coming and going from the message
  bus. Need to look into why this happens.

TODO
====

* Make the creation and attachment of a volume optional
* Enable specifying which device the volume is on
* Enable linking in the right node profile conf when creating a node host
* Enable specifying the domain to update the node host DNS
* Improve logging

