module Installer
  class Assistant
    attr_accessor :config

    def initialize config
      self.config = config
    end

    def run
      if self.config.role.nil?
        puts "Running assisted"
      else
        puts "Running headless"
      end
    end
  end
end

