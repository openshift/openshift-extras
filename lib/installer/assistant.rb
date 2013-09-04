require 'highline/import'
require 'installer/deployment'
require 'installer/helpers'
require 'installer/host_instance'
require 'installer/workflow'

module Installer
  class Assistant
    include Installer::Helpers

    attr_accessor :config, :deployment, :workflow, :workflow_cfg, :unattended

    def initialize config
      @config = config
      @deployment = config.get_deployment
      @unattended = config.workflow.nil? ? false : true
    end

    def run
      if not unattended
        ui_welcome_screen
      else
        unless deployment.is_complete?
          puts translate :exit_no_deployment
          return 1
        end
        puts translate :info_wait_config_validation
        begin
          deployment.is_valid?(:full)
        rescue Exception => msg
          say "\nThe deployment validity test returned an an error:\n#{msg.inspect}\nUnattended deployment terminated.\n"
        end
      end
    end

    def workflow_cfg_complete?
      return false if workflow.nil? or workflow_cfg.nil? or workflow_cfg.empty?
      workflow.questions.each do |q|
        return false if not workflow_cfg.has_key?(q.id) or not q.valid_answer? workflow_cfg[q.id]
      end
      return false is workflow.questions.length != workflow_cfg.keys.length
      true
    end

    def ui_title
      ui_newpage
      say translate(:title)
      puts "----------------------------------------------------------------------\n\n"
    end

    def ui_newpage
      puts "\n"
    end

    def ui_welcome_screen
      ui_title
      say translate :welcome
      say translate :intro
      puts "\n"
      choose do |menu|
        menu.header = translate :select_workflow
        Installer::Workflow.list.each do |workflow|
          menu.choice(workflow[:desc]) { ui_workflow(workflow[:id]) }
        end
        menu.choice(translate(:choice_exit_installer)) { return 0 }
      end
    end

    def ui_workflow id
      @workflow = Installer::Workflow.find(id)
      @workflow_cfg = config.get_workflow_cfg(id)
      ui_newpage
      if workflow.check_deployment?
        if not deployment.is_complete?
          say translate :info_force_run_deployment_setup
          ui_edit_deployment
        else
          ui_show_deployment
        end
        while agree("\nDo you want to make any changes to your deployment?(Y/N) ", true)
          ui_edit_deployment
          ui_show_deployment
        end
      end
      ui_edit_workflow
      return 0
    end

    def ui_edit_workflow
      if not workflow_cfg.empty?
        ui_show_workflow
      end
      begin
        workflow.questions.each do |question|
          question.ask(workflow_cfg)
        end
      end while not agree("\nDo you want to make any changes to your answers?(Y/N) ", true)
    end

    def ui_show_workflow
      ui_newpage
      say translate :workflow_summary
      puts "\n"
      workflow.questions.each do |question|
        if workflow_cfg.has_key?(question.id)
          say "#{question.id}: #{answer}"
      end
    end

    def ui_edit_deployment
      Installer::Deployment.role_map.each_pair do |role,hkey|
        list_count = list_role role
        if list_count == 0
          say "\nYou must add a host instance to the #{hkey} list."
          ui_modify_role_list role
        end
        while agree("\nDo you want to modify the #{hkey} list?(Y/N) ", true)
          ui_modify_role_list role
        end
      end
    end

    def ui_show_deployment
      ui_newpage
      say translate :deployment_summary
      Installer::Deployment.role_map.each_pair do |role,hkey|
        list_role role
      end
    end

    def ui_modify_role_list role
      list = deployment.get_role_list(role)
      if list.length
        if role == :node
          say "\nModifying the " + Installer::Deployment.role_map[role] + " list.\n\n"
          choose do |menu|
            menu.header = "Select the number of the #{role.to_s} host instance that you wish to modify"
            for i in 0..(list.length - 1)
              menu.choice(list[i].summarize) { ui_edit_host_instance list[i], list.length, i }
            end
            menu.choice("Add a new #{role.to_s}") { ui_edit_host_instance Installer::HostInstance.new(role) }
          end
        else
          ui_edit_host_instance list[0], list.length, 0
        end
      else
        say "Add a new #{role.to_s}"
        ui_edit_host_instance Installer::HostInstance.new(role)
      end
    end

    def ui_edit_host_instance host_instance, role_count=0, index=nil
      rolename = Installer::Deployment.role_map[host_instance.role].chop
      puts "\n"
      if index.nil?
        say "Adding a new #{rolename}"
      elsif host_instance.role == :node
        say "Modifying #{rolename} number #{index + 1}"
      else
        say "Modifying #{rolename}"
      end
      if host_instance.role == :node and role_count > 1
        choose do |menu|
          menu.header = "Do you want to delete this #{rolename} or update it?"
          menu.choice("Update it") {
            edit_host_instance host_instance
            deployment.update_host_instance! host_instance, index
            say "Updated the #{rolename} host instance."
          }
          menu.choice("Delete it") {
            deployment.remove_host_instance! host_instance, index
            say "Deleted the #{rolename} host instance."
          }
        end
      else
        edit_host_instance host_instance
        if index.nil?
          deployment.add_host_instance! host_instance
        else
          deployment.update_host_instance! host_instance, index
        end
      end
      puts "\n"
      list_role host_instance.role
    end

    def edit_host_instance host_instance
      host_instance_is_valid = false
      while not host_instance_is_valid
        host_instance.host = ask("Host name: ") { |q|
          if not host_instance.host.nil?
            q.default = host_instance.host
          end
          q.validate = lambda { |p| is_valid_hostname_or_ip_addr?(p) }
          q.responses[:not_valid] = "Enter a valid hostname or IP address"
        }
        if host_instance.role == :broker
          host_instance.port = ask('REST API port: ', Integer) { |q|
            q.default = host_instance.port.nil? ? 443 : host_instance.port
            q.validate = lambda { |p| is_valid_port_number?(p) }
            q.responses[:not_valid] = translate :invalid_port_number_response
          }
        end
        host_instance.user = ask("OpenShift username on #{host_instance.host}: ") { |q|
          if not host_instance.user.nil?
            q.default = host_instance.user
          end
          q.validate = lambda { |p| is_valid_username?(p) }
          q.responses[:not_valid] = "Enter a valid linux username"
        }
        if host_instance.role == :dbserver
          host_instance.db_port = ask("Database access port: ", Integer) { |q|
            q.default = host_instance.db_port.nil? ? 27017 : host_instance.db_port
            q.validate = lambda { |p| is_valid_port_number?(p) }
            q.responses[:not_valid] = translate :invalid_port_number_reponse
          }
          host_instance.db_user = ask("Database username: ") { |q|
            if not host_instance.db_user.nil?
              q.default = host_instance.db_user
            end
            q.validate = lambda { |p| is_valid_username?(p) }
            q.responses[:not_valid] = "Enter a valid database username"
          }
        else
          host_instance.messaging_port = ask("MCollective client port: ", Integer) { |q|
            q.default = host_instance.messaging_port.nil? ? 61616 : host_instance.messaging_port
            q.validate = lambda { |p| is_valid_port_number?(p) }
            q.responses[:not_valid] = translate :invalid_port_number_response
          }
        end
        if (host_instance.role == :broker and host_instance.port == host_instance.messaging_port)
          say "The REST API and the messaging client cannot listen on the same port (#{host_instance.port}). Reconfigure this host instance."
        else
          host_instance_is_valid = true
        end
      end
    end

    def list_role role
      puts "\n" + Installer::Deployment.role_map[role] + "\n"
      list = deployment.get_role_list(role)
      if list.length
        list.each do |host_instance|
          list_host_instance host_instance
        end
      else
        puts "\t[None]\n"
      end
      list.length
    end

    def list_host_instance host_instance
      lines = []
      Installer::HostInstance.attrs.each do |attr|
        value = host_instance.send(attr)
        if not value.nil?
          lines << "#{attr.to_s.split('_').map{ |word| word == 'db' ? 'DB' : word.capitalize}.join(' ')}: #{value}"
        end
      end
      puts "  * " + lines.join("\n    ")
    end
  end
end
