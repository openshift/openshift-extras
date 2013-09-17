Openshift Security Tools
==========================================================

These scripts are provided as examples only and may, or may not work
in your environment or with later changes to OpenShift.


* ip-iptables

Creates a large iptables table which restricts gears from contacting
each other's non-exposed IP addresses.


* ip-selinux

Creates SELinux node entries which prevent gears from binding to all
but their own allocated IP address space.
