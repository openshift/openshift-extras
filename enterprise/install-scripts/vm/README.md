# Enterprise VM: kickstart and supporting files

This folder contains a script to modify the generic openshift.ks file
for building a brew-based Enterprise VM image.

The VM kickstart is built from several parts, including some
possibly-sensitive internal details. As such, the sensitive parts are
not checked into git, including the resulting kickstart.

The workflow for generating an image is:

* cp parts/definitions.sh{.template,}
* fill in parts/definitions.sh appropriately
* cd ../
* make
* brew build-image with vm/openshift-vm.ks and options e.g.:

    brew image-build openshift-enterprise-test-image 2.0.3 rhose-2.0-rhel-6-image <base-img-url> x86_64 --kickstart=vm/openshift-vm.ks image-builds --format=qcow2 --distro=RHEL-6.5 --repo <yum-repo-url>

...or, beginning with koji-1.8.0-12 you can fill in the conf file and:

    brew image-build --config=image-build.conf

