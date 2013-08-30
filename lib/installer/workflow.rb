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

      def list
        @list ||= file_cache.map{ |workflow| { :id => workflow['ID'], :desc => workflow['Description'] } }
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

    attr_reader :name, :description, :id, :questions, :executable, :path

    def initialize config
      @id = config['ID']
      @name = config['Name']
      @description = config['Description']
      @remote_execute = (config.has_key?('ExecuteOnTarget') and config['ExecuteOnTarget'].downcase == 'n') ? false : true
      @check_deployment = (config.has_key?('SkipDeploymentCheck') and config['SkipDeploymentCheck'].downcase == 'y') ? false : true
      @path = gem_root_dir + "/workflows/" + id
      @questions = config.has_key?('Questions') ? config['Questions'].map{ |q| Installer::Question.new(self, q) } : []
      @executable = Installer::Executable.new(self, config['Executable'])
    end

    def check_deployment?
      @check_deployment
    end

    def remote_execute?
      @remote_execute
    end
  end
end
