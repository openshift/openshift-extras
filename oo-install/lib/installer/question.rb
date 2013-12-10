require 'highline'
require 'installer/deployment'

module Installer
  class Question
    attr_reader :workflow, :id, :text, :type

    def initialize workflow, question_config
      @workflow = workflow
      @id = question_config['Variable']
      @text = question_config['Text']
      @type = question_config['AnswerType'] || 'text'
    end

    def ask deployment, workflow_cfg
      if type == 'text'
        workflow_cfg[id] = HighLine.ask(text) { |q|
          if workflow_cfg.has_key?(id)
            q.default = workflow_cfg[id]
          end
        }
      elsif type == 'role'
        choose do |menu|
          menu.header = text
          Installer::Deployment.role_map.each_pair do |role,group|
            menu.choice(group.chop) { workflow_cfg[id] = role.to_s }
          end
        end
      elsif type.start_with?('rolehost')
        role = type.split(':')[1].to_sym
        choose do |menu|
          menu.header = text
          deployment.send(Installer::Deployment.list_map[role]).each do |host_instance|
            menu.choice(host_instance.summarize) { workflow_cfg[id] = host_instance.host }
          end
        end
      elsif type == 'Integer'
        workflow_cfg[id] = HighLine.ask(text, Integer) { |q|
          if workflow_cfg.has_key?(id)
            q.default = workflow_cfg[id]
          end
        }
      elsif type == 'version'
        if workflow.versions.keys.length == 1
          workflow_cfg[id] = workflow.versions.keys[0]
        else
          workflow_cfg[id] = HighLine.ask(text) { |q|
            if workflow_cfg.has_key?(id) and workflow.versions[workflow_cfg[id]]
              q.default = workflow_cfg[id]
            end
            q.validate = lambda { |p| workflow.versions[p.to_s] }
            q.responses[:not_valid] = "Supported versions are #{workflow.versions.keys.sort.join(', ')}"
          }.to_s
        end
      end
    end

    def is_valid?(deployment, value, check=:basic)
      errors = []
      if (type == 'role' and not Installer::Deployment.role_map.has_key?(value.to_sym)) or
        (type.start_with?('rolehost') and deployment.hosts.select{ |h| h.host == value and h.roles.include?(type.split(':')[1].to_sym) }.length == 0) or
        (type == 'text' and not is_valid_string?(value)) or
        (type == 'Integer' and not value.to_s.match(/\d+/)) or
        (type == 'version' and not workflow.versions.include?(value))
        return false if check == :basic
        errors << Installer::WorkflowConfigValueException.new("The configuration for workflow '#{workflow.id}' contains an invalid value '#{value}' for configuration setting '#{id}'.")
      end
      return true if check == :basic
      errors
    end
  end
end
