Node Manager - framework for automating node scale events
=========================================================

This is the beginning of a pluggable framework for scaling OpenShift's
node infrastructure automatically. The premise of this framework is that
OpenShift has the information to make a decision on when and how to scale
and is integrated into a system from which it can request the resources
necessary. This is the "push" approach, meaning OpenShift initiates the
scale events.

In contrast, the "pull" approach would mean that OpenShift passively
supplies the data necessary for making a decision and an external system
(e.g. monitoring or an IaaS plugin) retrieves the data and applies its
logic to implement scaling. This framework could eventually serve as
the basis for providing "pull" data as well.

Please consider the existing code a proof of concept.  It is not nearly
as robust or fault-tolerant as production code needs to be.  The hope
is that if the approach is sound, the code will improve over time.

Central scaling logic
=====================

For an OpenShift installation to automate node elasticity, it needs:

1. Logic to determine when and where scaling should occur
2. The means to request resources (or their removal)

This implementation includes a capacity checker service
(openshift-nodemgr) on the broker utilizing the oo-stats library from
/opt/rh/openshift/nodemgr/oo-capacity-checker to determine when and
where to scale. The parameters for this service are located in
/etc/openshift/nodemgr/capacity.conf

Once it has determined that a scaling event is necessary,
oo-capacity-checker calls a event handler (specified in capacity.conf)
to actually implement the logic depending on the method an OpenShift
system administrator has available.

Output from oo-capacity-checker is logged to:
/var/log/openshift/broker/openshift-nodemgr.log

Event handlers
==============

The event handler for scaling is specified in capacity.conf. It should
be located in a subdirectory of /opt/rh/openshift/nodemgr/ and contain
a script named "event" which is the entry point for nodemgr to request
an event from that handler. Configuration for event handlers should be
located in the handler's subdirectory of /etc/openshift/nodemgr/

The existing code includes two event handlers that can be configured:

1. stdout - a no-op event handler that just results in event notices
   being logged. This is the default handler.
2. openstack-nova - an event handler that uses the nova client to
   request resources from an OpenStack API.

Future event handlers (you might contribute these!) might include:

1. email - email a system administrator when resources are needed
2. spool - write event specifications to a location which is made
   available (e.g. via the web) for some external service to read and
   take action on
3. Various IaaS-specific integrations

Events
======

Currently the only event requested is "create-node". The district (if any)
and profile the new node host should have are command-line arguments.

Compacting a district by removing a node requires first moving all of
the gears off of the node, which is not well-enabled by the existing
OpenShift tools (gear moving is a manual process, performed one gear at
a time, and somewhat error prone. This will be improved in the future
but it is not clear when). This framework may provide tools to do this
in the future.

