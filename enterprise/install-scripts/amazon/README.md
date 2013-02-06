Amazon Installation
==================

Background
----------

For this CloudFormation template to work, we are using init.d scripts
that will run a script embedded in the UserData for the image.  The
scripts are from https://forums.aws.amazon.com/thread.jspa?threadID=87599

New images can be built with the cloudformation shell script and the
resulting image will be saved as an AMI named:

    oso-cloudfoundation-base

Running
-------

1. Upload the OpenShift.template as your CloudFormation Stack
2. Watch it run...

Updating from the source kickstart
----------------------------------

Each time you update the canonical kickstart file in the root
directory, you should re-generate the script based forms using
the following command:

    make clean all
