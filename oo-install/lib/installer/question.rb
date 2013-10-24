require 'highline'

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
      elsif type == 'rolelist'
        legal_values = Installer::Deployment.roles.join(', ') + ', all'
        qtext = [text, ' [', legal_values, ']'].join
        workflow_cfg[id] = HighLine.ask(qtext) { |q|
          if workflow_cfg.has_key?(id)
            q.default = workflow_cfg[id]
          end
          q.validate = lambda { |p| is_valid_role_list?(p) }
          q.responses[:not_valid] = "Provide a value or list of values from: #{legal_values}."
        }
      elsif type.start_with?('rolehost')
        role = type.split(':')[1]
        choose do |menu|
          menu.header = text
          deployment.list_host_instances_for_workflow(role).each do |item|
            menu.choice(item[:text]) { workflow_cfg[id] = item[:value] }
          end
        end
      elsif type == 'remotehost'
        workflow_cfg[id] = HighLine.ask(text) { |q|
          if workflow_cfg.has_key?(id)
            q.default = workflow_cfg[id]
          end
          q.validate = lambda { |p| is_valid_remotehost?(p) }
          q.responses[:not_valid] = "Provide a value in the form <username>@<hostname>[:<ssh_port>]"
        }
      elsif type == 'mongodbhost'
        workflow_cfg[id] = HighLine.ask(text) { |q|
          if workflow_cfg.has_key?(id)
            q.default = workflow_cfg[id]
          end
          q.validate = lambda { |p| is_valid_mongodbhost?(p) }
          q.responses[:not_valid] = "Provide a value in the form [username:password@]host1[:port1][,host2[:port2],...[,hostN[:portN]]]"
        }
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

    def valid? deployment, value
      if type == 'remotehost'
        return is_valid_remotehost?(value)
      elsif type == 'mongodbhost'
        return is_valid_mongodbhost?(value)
      elsif type == 'role'
        return false if not Installer::Deployment.role_map.keys.map{ |role| role.to_s }.include?(value)
      elsif type.start_with?('rolehost')
        return false if deployment.find_host_instance_for_workflow(value).nil?
      end
      true
    end
  end
end
