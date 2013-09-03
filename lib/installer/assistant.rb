require 'highline/import'
require 'installer/deployment'
require 'installer/helpers'
require 'installer/workflow'

module Installer
  class Assistant
    include Installer::Helpers

    attr_accessor :config, :deployment, :workflow

    def initialize config
      @config = config
      @deployment = config.get_deployment
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
      ui_newpage
      if workflow.check_deployment?
        if not config.complete_deployment?
          puts translate :info_force_run_deployment_setup
          ui_edit_deployment
        else
          ui_show_deployment
        end
      end
      while agree("\nDo you want to make any changes to your deployment?(Y/N) ", true)
        ui_edit_deployment
        ui_show_deployment
      end
      return 0
    end

    def ui_edit_deployment
      Installer::Deployment.role_map.each_pair do |role,hkey|
        list_count = list_role role
        if list_count == 0
          say "\nYou must add a system to the #{hkey} list."
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
            menu.header = "Select the number of the system that you wish to modify"
            for i in 0..(list.length - 1)
              system = list[i]
              menu.choice(system.summarize) { ui_add_edit_system role, list.length, i }
            end
            menu.choice("Add a new #{role.to_s}") { ui_add_edit_system role, list.length }
          end
        else
          ui_add_edit_system role, list.length, 0
        end
      else
        say "Add a new #{role.to_s}"
        ui_add_edit_system role, 0
      end
    end

    def ui_add_edit_system role, role_count, index=nil
      rolename = Installer::Deployment.role_map[role].chop
      puts "\n"
      if index.nil?
        say "Adding a new #{rolename}"
      elsif role == :node
        say "Modifying #{rolename} number #{index + 1}"
      else
        say "Modifying #{rolename}"
      end
      perform_edit = false
      if role == :node and role_count > 1 and not index.nil?
        choose do |menu|
          menu.header = "Do you want to delete this #{rolename} or update it?"
          menu.choice("Update it") { say "Proceeding with update"; perform_edit = true }
          menu.choice("Delete it") { deployment.remove_system role, index }
        end
      else
        perform_edit = true
      end
      if perform_edit
        system = index.nil? ? Installer::System.new(role) : deployment.get_role_list(role)[index]
        system_is_valid = false
        while not system_is_valid
          system.host = ask("#{rolename} host name: ") { |q|
            if not system.host.nil?
              q.default = system.host
            end
            q.validate = lambda { |p| is_valid_hostname_or_ip_addr?(p) }
            q.responses[:not_valid] = "Enter a valid hostname or IP address"
          }
          if role == :broker
            system.port = ask('REST API port: ', Integer) { |q|
              q.default = system.port.nil? ? 443 : system.port
              q.validate = lambda { |p| is_valid_port_number?(p) }
              q.responses[:not_valid] = translate :invalid_port_number_response
            }
          end
          system.user = ask("OpenShift username on #{system.host}: ") { |q|
            if not system.user.nil?
              q.default = system.user
            end
            q.validate = lambda { |p| is_valid_username?(p) }
            q.responses[:not_valid] = "Enter a valid linux system username"
          }
          if role == :dbserver
            system.db_port = ask("Database access port: ", Integer) { |q|
              q.default = system.db_port.nil? ? 27017 : system.db_port
              q.validate = lambda { |p| is_valid_port_number?(p) }
              q.responses[:not_valid] = translate :invalid_port_number_reponse
            }
            system.db_user = ask("Database username: ") { |q|
              if not system.db_user.nil?
                q.default = system.db_user
              end
              q.validate = lambda { |p| is_valid_username?(p) }
              q.responses[:not_valid] = "Enter a valid database username"
            }
          else
            system.messaging_port = ask("MCollective client port: ", Integer) { |q|
              q.default = system.messaging_port.nil? ? 61616 : system.messaging_port
              q.validate = lambda { |p| is_valid_port_number?(p) }
              q.responses[:not_valid] = translate :invalid_port_number_response
            }
          end
          if (role == :broker and system.port == system.messaging_port)
            say "The REST API and the messaging client cannot listen on the same port (#{system.port}). Reconfigure this system."
          else
            system_is_valid = true
          end
        end
        puts "\n"
        if index.nil?
          deployment.add_system role, system
          say "Added new #{rolename} system."
        else
          list = deployment.get_role_list role
          list[index - 1] = system
          deployment.set_role_list role, list
          say "Updated the #{rolename} system."
        end
      else
        say "Deleted the #{rolename} system."
      end
      config.set_deployment deployment
      config.save_to_disk
      list_role role
    end

    def list_role role
      puts "\n" + Installer::Deployment.role_map[role] + "\n"
      list = deployment.get_role_list(role)
      if list.length
        list.each do |system|
          list_system system
        end
      else
        puts "\t[None]\n"
      end
      list.length
    end

    def list_system system
      Installer::System.attrs.each do |attr|
        value = system.send(attr)
        if not value.nil?
          say "\t#{attr.to_s.split('_').map{ |word| word == 'db' ? 'DB' : word.capitalize}.join(' ')}: #{value}\n"
        end
      end
    end
  end
end
