require 'highline/import'

module Installer
  class Question
    attr_reader :workflow, :id, :text, :type

    def initialize workflow, question_config
      @workflow = workflow
      @id = question_config['Variable']
      @text = question_config['Text']
      @type = question_config['AnswerType']
    end

    def ask workflow_cfg
      if type == 'role'
        choose do |menu|
          menu.header = text
          Installer::Deployment.role_map.each_pair do |role,group|
            menu.choice(group.chop) { workflow_cfg[id] = role.to_s }
          end
        end
      elsif type == 'rolehost'
        deployment = workflow.config.get_deployment
        choose do |menu|
          menu.header = text
          deployment.list_host_instances_for_workflow.each do |item|
            menu.choice(item[:text]) { workflow_cfg[id] = item[:value] }
          end
        end
      elsif type == 'remotehost'
        workflow_cfg[id] = ask(text) { |q|
          if workflow_cfg.has_key?(id)
            q.default = workflow_cfg[id]
          end
          q.validate = lambda { |p| is_valid_remotehost?(p) }
          q.responses[:not_valid] = "Provide a value in the form <username>@<hostname>[:<ssh_port>]"
        }
      elsif type == 'mongodbhost'
        workflow_cfg[id] = ask(text) { |q|
          if workflow_cfg.has_key?(id)
            q.default = workflow_cfg[id]
          end
          q.validate = lambda { |p| is_valid_mongodbhost?(p) }
          q.responses[:not_valid] = "Provide a value in the form [username:password@]host1[:port1][,host2[:port2],...[,hostN[:portN]]]"
        }
      elsif type == 'Integer'
        workflow_cfg[id] = ask(text, Integer) { |q|
          if workflow_cfg.has_key?(id)
            q.default = workflow_cfg[id]
          end
        }
      end
    end

    def valid? value
      if type == 'remotehost'
        return is_valid_remotehost?(value)
      elsif type == 'mongodbhost'
        return is_valid_mongodbhost?(value)
      elsif type == 'role'
        return false if not Installer::Deployment.role_map.keys.map{ |role| role.to_s }.include?(value)
      elsif type == 'rolehost'
        return false if deployment.find_host_instance_for_workflow(value).nil?
      end
      true
    end
  end
end
