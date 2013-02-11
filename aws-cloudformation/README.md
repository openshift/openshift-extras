Install OpenShift on Red Hat Enterprise Linux using AWS CloudFormation
======================================================================

This method of creating instances and configuring them on AWS CloudFormation relies upon the ability to initilize an instance using a script provided in the instance user-data. The AMI must have cloud-init installed and chkconfig'd on.  I have prepared an AMI, referenced in the template file; however, it's a private AMI.  The reason I build my own AMI is that I wanted to install OpenShift on the latest Red Hat Enterprise Linux (even a pre-released snapshot).  Feel free to create your own AMI.

Step 1:
Make sure you have access to the CloudFormation console within the Amazon AWS web console.
https://console.aws.amazon.com/cloudformation/home

Step 2:
The provided OpenShift install script makes some assumptions about the yum repo locations for Red Hat Enterprise Linux and OpenShift.  It also assumes certificate based access control to those yum repositories. You'll either need to have access to the default AMI, which is referenced by the template OR adjust your repository urls and client key/cert locations.

Step 3:
Use the 'Create New Stack' wizard.  Use one of the provided templates in this git repo.  Note, if you've forked the repo, you will probably need to adjust the file urls to reflect the actual location of the shell script.  *Important*, The CloudFormation template will create public instances that will need to download the OpenShift install script from a public location.  You need to make sure the url that points to the OpenShift install script is publicly accessible.

Step 4:
Make sure you pick a unique name for the domain prefix, otherwise the stack creation will fail.

Step 5:
You can monitor the stack progress in the AWS CloudFormation web console.  Once it's complete, you're ready to use the infrastructure.
