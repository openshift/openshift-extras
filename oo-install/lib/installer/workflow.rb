require 'installer/exceptions'
require 'installer/helpers'
require 'installer/executable'
require 'installer/question'

module Installer
  class Workflow
    include Installer::Helpers

    class << self
      def ids
        @ids ||= file_cache.map{ |workflow| workflow['ID'] }
      end

      def list(context)
        show_list = []
        file_cache.each do |workflow_hash|
            if (not workflow_hash.has_key?('Type') and context == :origin) or
               (workflow_hash.has_key?('Type') and workflow_hash['Type'].to_sym == context)
              show_list << { :id => workflow_hash['ID'], :desc => workflow_hash['Description'] }
            end
        end
        show_list
      end

      def find id
        unless ids.include?(id)
          raise Installer::WorkflowNotFoundException.new "Could not find a workflow with id #{id}."
        end
        new(file_cache.find{ |workflow| workflow['ID'] == id })
      end

      private
      def file_path
        @file_path ||= gem_root_dir + '/conf/workflows.yml'
      end

      def file_cache
        @file_cache ||= validate_and_return_config
      end

      def required_fields
        %w{ID Name Description Executable}
      end

      def parse_config_file
        unless File.exists?(file_path)
          raise Installer::WorkflowFileNotFoundException.new
        end
        YAML.load_stream(open(file_path))
      end

      def validate_and_return_config
        parse_config_file.each do |workflow|
          required_fields.each do |field|
            if not workflow.has_key?(field)
              raise Installer::WorkflowMissingRequiredSettingException.new "Required field #{field} missing from workflow entry:\n#{workflow.inspect}\n\n"
            end
          end
        end
        parse_config_file
      end
    end

    attr_reader :name, :type, :description, :id, :questions, :executable, :path

    def initialize config
      @id = config['ID']
      @name = config['Name']
      @type = config.has_key?('Type') ? config['Type'].to_sym : :origin
      @description = config['Description']
      @remote_execute = (config.has_key?('RemoteDeployment') and config['RemoteDeployment'].downcase == 'y') ? true : false
      @check_deployment = (config.has_key?('SkipDeploymentCheck') and config['SkipDeploymentCheck'].downcase == 'y') ? false : true
      @check_subscription = (config.has_key?('SubscriptionCheck') and config['SubscriptionCheck'].downcase == 'y') ? true : false
      if config.has_key?('NonDeployment') and config['NonDeployment'].downcase == 'y'
        @non_deployment = true
        @remote_execute = false
        @check_deployment = false
      else
        @non_deployment = false
      end
      workflow_dir = config.has_key?('WorkflowDir') ? config['WorkflowDir'] : id
      @path = gem_root_dir + "/workflows/" + workflow_dir
      @questions = config.has_key?('Questions') ? config['Questions'].map{ |q| Installer::Question.new(self, q) } : []
      @executable = Installer::Executable.new(self, config['Executable'])
    end

    def check_deployment?
      @check_deployment
    end

    def check_subscription?
      @check_subscription
    end

    def remote_execute?
      @remote_execute
    end

    def non_deployment?
      @non_deployment
    end
  end
end
