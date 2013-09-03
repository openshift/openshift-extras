lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require 'installer/version'

Gem::Specification.new do |spec|
  spec.name          = "oo-install"
  spec.version       = Installer::VERSION
  spec.authors       = ["N. Harrison Ripps"]
  spec.email         = ["hripps@redhat.com"]
  spec.description   = %q{The installer is a helper app that guides a user through a few different OpenShift deployment options.}
  spec.summary       = %q{This utility guides a user in the deployment of a basic OpenShift system}
  spec.homepage      = ""
  spec.license       = "MIT"

  spec.files         = `git ls-files`.split($/)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  #spec.add_dependency "curses"
  spec.add_dependency "highline", "~> 1.6.11"
  spec.add_dependency "i18n"
  spec.add_dependency "versionomy", "~> 0.4.4"

  spec.add_development_dependency "bundler", "~> 1.3"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "rspec",   ">= 2.8.0"
  spec.add_development_dependency "cucumber"
end
