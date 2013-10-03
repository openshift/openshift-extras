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

  spec.add_dependency "highline"
  spec.add_dependency "i18n"
  spec.add_dependency "net-ssh"
  spec.add_dependency "terminal-table"
  spec.add_dependency "bundler"
  spec.add_dependency "rake"
  spec.add_dependency "rspec"
end
