# oo-install

This package is a general-purpose installation tool for [OpenShift](http://www.openshift.com/). It supports a number of deployment scenarios and is extensible through the definition of installer Workflows.

## Installation
The latest stable version of the installer is available for "curl-to-shell" use from the OpenShift cloud. To use it, run:

    sh <(curl -s http://oo-install.rhcloud.com/)

from the command line of any system with ruby 1.8.7 or above plus unzip and curl. Depending on what you are trying to install (OpenShift Origin versus OpenShift Enterprise), your target system may require additional RPMs. The installer will attempt to suggest RPM packages to install to provide the necessary utilities.

## Running oo-install from source
If you would prefer to run the installer from source, you will need to use the [bundler](http://bundler.io/) gem to set up the right environment.

1. Clone [openshift-extras](https://github.com/openshift/openshift-extras/)
2. `cd openshift-extras/oo-install`
3. `bundle install`
4. `bundle exec bin/oo-install`

## Command-line options

The following command-line options are currently supported:

    -a, --advanced-mode              Enable access to message server and db server customization.
    -c, --config-file FILEPATH       The path to an alternate config file
        --create-config              Use with "-c" to create and use a new alternate config file
    -w, --workflow WORKFLOW_ID       The installer workflow for unattended deployment.
    -e, --enterprise-mode            Show OpenShift Enterprise options (ignored in unattended mode)
        --openshift-version VERSION  Specify the version of OpenShift to be installed (default is latest)
    -s, --subscription-type TYPE     The software source for installation packages.
    -u, --username USERNAME          Red Hat Login username
    -p, --password PASSWORD          Red Hat Login password

- - -

**NOTE**:  
In order to pass arguments to the curl-to-shell command, enclose them in quotes.

    sh <(curl -s http://oo-install.rhcloud.com/) "-c alternate/config/file.yml -w origin_add_node -s yum"

- - -

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request
