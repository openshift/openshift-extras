# Installation script #
The kickstarts and install scripts found here are mostly self documenting.
They set reasonable defaults but are almost endlessly configurable via
environment variaibles.

## Generating the extra scripts from the kickstart ##
One important thing to understand when making changes is that you will only
need to edit the openshift.ks file found in this directory.  Once you have made
your changes you can run `make` to generate the other files.  At that point you
can add all the files to your pull request and send it our way.

Normally we wouldn't commit generated files into the repository however in this
case it is needed for security reasons.  Our jenkins jobs will test pull
requests and we cannot have code executed on the CI server.  We scp the
unmodified repository to a remote VM and run it there.  Someday we'll make it
so that issuing the `make` call could happen on the remote VM but that isn't
how the build scripts work today.

## Contributing

Create a pull request against this repository.  From there the maintainers will
review the change and the details can be ironed out.  Once it's ready for
testing the maintainers will create a bug that will trigger our QE workflow to
have the pull request merged.
