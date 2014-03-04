# Enterprise VM: kickstart and supporting files

This foler contains a script to modify the openshift.ks file for building a brew-based Enterprise VM.

In order for the VM to work correctly, the following files must be packaged as part of an official OSE RPM:

* welcome.html
* com.redhat.OSEWelcome.desktop

Once this is done, the TODOs in the `setup_vm_user()` function of openshift.ks should be updated with the correct symbolic link commands.
