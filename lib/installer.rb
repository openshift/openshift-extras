require 'logger'
require 'pp'

module Installer
  autoload :Assistant, 'installer/assistant'
  autoload :Config,    'installer/config'
  autoload :Helpers,   'installer/helpers'
  autoload :Task,      'installer/task'
  autoload :VERSION,   'installer/version'
end
