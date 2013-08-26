# Originator

The Originator is a helper app that is invoked when a user starts up the OpenShift Origin VM. This app guides the user through a few different Origin deployment options.

## Installation

Add this line to your application's Gemfile:

    gem 'oo-originator'

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install oo-originator

## Usage

The Origin VM invokes this utility automatically upon startup. You can restart it from the shell by typing

    $ oo-originator

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request
