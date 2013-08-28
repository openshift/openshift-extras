require 'logger'
require 'pp'
require 'yaml'

module Installer
  autoload :Assistant, 'installer/assistant'
  autoload :Config,    'installer/config'
  autoload :Helpers,   'installer/helpers'
  autoload :Task,      'installer/task'
  autoload :VERSION,   'installer/version'
end
