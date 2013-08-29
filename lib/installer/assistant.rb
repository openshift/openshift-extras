module Installer
  class Assistant
    attr_accessor :config

    def initialize config
      @config = config
    end

    def run
      if self.config.workflow.nil?
        puts "Running assisted"
      else
        puts "Running headless"
      end
    end
  end
end

