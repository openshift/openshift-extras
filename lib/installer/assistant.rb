require 'highline/import'
require 'installer/helpers'
require 'installer/workflow'

module Installer
  class Assistant
    include Installer::Helpers

    attr_accessor :config, :workflow

    def initialize config
      @config = config
    end

    def run
      if config.workflow.nil?
        ui_welcome_screen
      else
        unless config.complete_deployment?
          puts translate :exit_no_deployment
          return 1
        end
        puts translate :info_wait_config_validation
      end
    end

    def ui_title suffix=''
      system 'clear'
      puts "\n"
      say translate(:title) + (suffix == '' ? '' : ": #{suffix}")
      puts "----------------------------------------------------------------------\n\n"
    end

    def ui_welcome_screen
      ui_title
      say translate :welcome
      say translate :intro
      puts "\n"
      choose do |menu|
        menu.header = translate(:select_workflow)
        Installer::Workflow.list.each do |workflow|
          menu.choice(workflow[:desc]) { ui_workflow(workflow[:id]) }
        end
        menu.choice(translate(:choice_exit_installer)) { return 0 }
      end
    end

    def ui_workflow id
      @workflow = Installer::Workflow.find(id)
      ui_title workflow.description
      if workflow.check_deployment?
        if not config.complete_deployment?
          puts translate :info_force_run_deployment_setup
          ui_review_deployment
        else if agree("Do you want to review your deployment configuration? ", true))

        ui_review_deployment
      end
      return 0
    end

    def ui_review_deployment
    end
  end
end
