# Installation script #
The kickstarts and install scripts found here are mostly self documenting.
They set reasonable defaults but are almost endlessly configurable via
environment variables.

## Kickstart file and shell script ##
Alongside this README file, you will find openshift.ks, which is a kickstart
file with a large %post section that installs OpenShift Enterprise.  In the
generic/ subdirectory, you will find openshift.sh, which is a shell script that
is generated from the openshift.ks file.  These two files provide alternative
installation methods: you can use the kickstart file to boot a new host and
install OpenShift Enterprise running on Red Hat Enterprise Linux, or if you
already have Red Hat Enterprise Linux installed on a host, you can run
openshift.sh on that host to install OpenShift Enterprise.

## Generating the extra scripts from the kickstart ##
One important thing to understand when making changes is that you will only
need to edit the openshift.ks file found in this directory.  Once you have made
your changes, you can run `make` to generate the other files.  At that point,
you can add all the files to your pull request and send it our way.

Normally we wouldn't commit generated files into the repository; however, in
this case, it is needed for security reasons.  Our jenkins jobs will test pull
requests, and we cannot have code executed on the CI server.  We scp the
unmodified repository to a remote VM and run it there.  Someday we'll make it so
that the `make` could be issued on the remote VM, but that isn't how the build
scripts work today.

## Contributing
Create a pull request against this repository.  From there, the maintainers will
review the change, and the details can be ironed out.  Once it's ready for
testing, the maintainers will create a bug that will trigger our QE workflow to
have the pull request merged.
