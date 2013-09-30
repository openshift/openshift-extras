# oo-install

This package is a general-purpose installation tool for [OpenShift](http://www.openshift.com/). It supports a number of deployment scenarios and is extensible through the definition of installer Workflows.

## Installation

Add this line to your application's Gemfile:

    gem 'oo-install'

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install oo-install

## Usage

You can start the installer from the shell by typing

    $ oo-install

To run an unattended installation, use:

    $ oo-install -w <workflow_id>

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request
