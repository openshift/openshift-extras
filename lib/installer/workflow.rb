require 'installer/exceptions'

module Installer
  class Workflow
    class << self
      def ids
        @ids ||= file_cache.map{ |workflow| workflow['ID'] }
      end

      def list
        @list ||= file_cache.map{ |workflow| { :id => workflow['ID'], :desc => workflow['Description'] } }
      end

      def find id
        new(file_cache.find{ |workflow| workflow['ID'] == id })
      end

      private
      def file_cache
        @file_cache ||= validate_and_return_config
      end

      def required_fields
        %w{ID Name Description Executable}
      end

      def validate_and_return_config
        workflow_list = YAML.load_stream(open(gem_root_dir + '/conf/workflows.yml'))
        workflow_list.each do |workflow|
          required_fields.each do |field|
            if not workflow.has_key?(field) or workflow[field].blank?
              raise Installer::WorkflowMissingRequiredSettingException "Required field #{field} missing from workflow entry:\n#{workflow.inspect}\n\n"
            end
          end
        end
        workflow_list
      end
    end

    attr_reader :name, :description, :id, :questions, :executable

    def initialize config
      @id = config['ID']
      @name = config['Name']
      @description = config['Description']
      @questions = config.has_key?('Questions') ? config['Questions'].map{ |q| Installer::Question.new(q) } : []
      @executable = Installer::Executable.new(id, config['Executable'])
      @remote_execute = (config.has_key?('ExecuteOnTarget') and config['ExecuteOnTarget'].downcase == 'y') ? true : false
      @check_deployment = (config.has_key?('SkipDeploymentCheck') and config['SkipDeploymentCheck'].downcase == 'y') ? false : true
    end

    def check_deployment?
      @check_deployment
    end

    def remote_execute?
      @remote_execute
    end
  end
end
