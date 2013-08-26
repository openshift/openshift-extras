require 'logger'
require 'installer/version'

module Installer
  attr_accessor :config

  def originate(config)
    self.config = config
    if self.config.role.nil?
      Installer::Assistant.run
    else
      puts "Performing unattended #{self.config.role} installation."
      Installer::Task.install
    end
  end
end

