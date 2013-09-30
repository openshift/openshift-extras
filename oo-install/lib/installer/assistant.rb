require 'highline/import'
require 'installer/deployment'
require 'installer/helpers'
require 'installer/host_instance'
require 'installer/subscription'
require 'installer/workflow'
require 'terminal-table'

module Installer
  class Assistant
    include Installer::Helpers

    attr_reader :context
    attr_accessor :config, :deployment, :cli_subscription, :cfg_subscription, :workflow, :workflow_cfg, :unattended

    def initialize config, workflow_id=nil, assistant_context=:origin, cli_subscription=nil
      @config = config
      @context = assistant_context
      @deployment = config.get_deployment
      @cfg_subscription = config.get_subscription
      @cli_subscription = cli_subscription
      @unattended = workflow_id.nil? ? false : true
      @save_subscription = true
    end

    def run
      if not unattended
        ui_welcome_screen
      else
        # Check the Deployment
        unless deployment.is_complete?
          puts translate :exit_no_deployment
          return 1
        end
        puts translate :info_wait_config_validation
        begin
          deployment.is_valid?(:full)
        rescue Exception => msg
          say "\nThe deployment validity test returned an error:\n#{msg.inspect}\nUnattended deployment terminated.\n"
          return 1
        end

        # Check the Workflow settings
        puts translate(:info_config_is_valid)
        @workflow = Installer::Workflow.find(config.workflow_id)
        @workflow_cfg = config.get_workflow_cfg(config.workflow_id)
        if not workflow_cfg_complete?
          say translate :error_unattended_workflow_cfg
          say translate :unattended_not_possible
          return 1
        end

        # Check the subscription info
        if workflow.check_subscription?
          begin
            merged_subscription.is_valid?(:full)
          rescue Exception => msg
            say "\nThe subscription settings check returned an error:\n#{msg.inspect}\nUnattended deployment terminated.\n"
            return 1
          end
        end

        # Reach out to the remote hosts
        if workflow.remote_execute?
          failed_hosts = deployment.check_remote_ssh
          if not failed_hosts.empty?
            say translate :error_unattended_workflow_remote
            puts "  * " + failed_hosts.join("\n  * ") + "\n"
            say translate :unattended_not_possible
            return 1
          end
        end

        say translate :info_unattended_workflow_start

        # Hand it off to the workflow executable
        workflow.executable.run workflow_cfg, merged_subscription
      end
      0
    end

    def workflow_cfg_complete?
      if workflow.nil? or (workflow.questions.length > 0 and (workflow_cfg.nil? or workflow_cfg.empty?))
        return false
      end
      workflow.questions.each do |q|
        if not workflow_cfg.has_key?(q.id) or not q.valid? workflow_cfg[q.id]
          return false
        end
      end
      if workflow.questions.length != workflow_cfg.keys.length
        return false
      end
      true
    end

    def save_subscription?
      @save_subscription
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
        Installer::Workflow.list(context).each do |workflow|
          menu.choice(workflow[:desc]) { ui_workflow(workflow[:id]) }
        end
        menu.choice(translate(:choice_exit_installer)) { return 0 }
      end
    end

    def ui_workflow id
      @workflow = Installer::Workflow.find(id)
      @workflow_cfg = config.get_workflow_cfg(id)
      ui_newpage

      # Deployment check
      if workflow.check_deployment?
        if not deployment.is_complete?
          say translate :info_force_run_deployment_setup
          ui_edit_deployment
          ui_show_deployment
        else
          ui_show_deployment
        end
        while agree("\nDo you want to make any changes to your deployment?(Y/N) ", true)
          ui_edit_deployment
          ui_show_deployment
        end
      end

      # Subscription check
      ui_newpage
      if workflow.check_subscription?
        if not merged_subscription.is_complete?
          say translate :info_force_run_subscription_setup
          puts "\n"
          choose do |menu|
            menu.header = translate :select_subscription
            menu.choice('Add subscription settings to the installer configuration file') { say "\nEditing installer subscription settings" }
            menu.choice('Enter subscription settings now without saving them to disk') { @save_subscription = false; say "\nGetting subscription settings for this installation" }
          end
          ui_edit_subscription
        end
        ui_show_subscription
        while agree("\nDo you want to make any changes to the subscription info in the configuration file?(Y/N) ", true)
          @save_subscription = true
          ui_edit_subscription
          ui_show_subscription
        end
        while agree("\nDo you want to set any temporary subscription settings for this installation only?(Y/N) ", true)
          @save_subscription = false
          ui_edit_subscription
          ui_show_subscription
        end
      end

      # Workflow questions
      if workflow.questions.length > 0
        ui_edit_workflow
      end

      # Workflow remote systems preflight
      if workflow.remote_execute?
        say "\nPreflight check: verifying remote system availability."
        failed_hosts = deployment.check_remote_ssh
        if not failed_hosts.empty?
          say "\n" + translate(:warning_ssh_issues)
          failed_hosts.each do |host_info|
            puts "  * #{host_info}"
          end
          say "\n" + translate(:unattended_not_possible)
          if not agree("Do you want to proceed anyway?(Y/N) ", true)
            say "\nExiting."
            exit
          end
        end
      end

      unless workflow.non_deployment?
        say "\nDeploying workflow '#{id}'."
      end

      # Hand it off to the workflow executable
      workflow.executable.run workflow_cfg, merged_subscription
      return 0
    end

    def ui_edit_workflow
      if not workflow_cfg.empty?
        say "\nThese are your current settings for this workflow:"
        ui_show_workflow
      end
      while workflow_cfg.empty? or agree("\nDo you want to make any changes to your answers?(Y/N) ", true)
        workflow.questions.each do |question|
          puts "\n"
          question.ask(deployment, workflow_cfg)
        end
      end
      config.set_workflow_cfg workflow.id, workflow_cfg
      config.save_to_disk!
    end

    def ui_show_workflow
      ui_newpage
      say translate :workflow_summary
      puts "\n"
      workflow.questions.each do |question|
        if workflow_cfg.has_key?(question.id)
          say "#{question.id}: #{workflow_cfg[question.id]}"
        end
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
      unless deployment.dns.keys.length > 0
        say "\nYou must set some DNS-specific values."
        ui_modify_dns
      end
      while agree("\nDo you want to change the DNS settings?(Y/N) ", true)
        ui_modify_dns
      end
    end

    def ui_show_deployment
      ui_newpage
      say translate :deployment_summary
      Installer::Deployment.role_map.each_pair do |role,hkey|
        list_role role
      end
      list_dns
    end

    def ui_edit_subscription
      ui_newpage
      tgt_subscription = save_subscription? ? cfg_subscription : cli_subscription
      valid_types = Installer::Subscription.subscription_types.keys.map{ |t| t.to_s }.join(', ')
      tgt_subscription.subscription_type = ask("What type of subscription should be used? (#{valid_types}) ") { |q|
        if not merged_subscription.subscription_type.nil?
          q.default = merged_subscription.subscription_type
        end
        q.validate = lambda { |p| Installer::Subscription.subscription_types.has_key?(p.to_sym) }
        q.responses[:not_valid] = "Valid subscription types are #{valid_types}"
      }
      Installer::Subscription.subscription_types[tgt_subscription.subscription_type.to_sym][:attrs].each_pair do |attr,desc|
        question = (attr == :rh_password and not save_subscription?) ? '<%= @key %>' : "#{desc}? "
        if save_subscription? or not [:rh_username, :rh_password].include?(attr)
          question << "(Use '-' to leave unset) "
        end
        tgt_subscription.send "#{attr.to_s}=".to_sym, ask(question) { |q|
          if not merged_subscription.send(attr).nil?
            q.default = merged_subscription.send(attr)
          elsif save_subscription? or not [:rh_username, :rh_password].include?(attr)
            q.default = '-'
          end
          if attr == :rh_password
            q.echo = '*'
            if not save_subscription?
              q.verify_match = true
              q.gather = {
                "Red Hat Account password? " => '',
                "Type password again to verify: " => '',
              }
            end
          end
          q.validate = lambda { |p| p == '-' or Installer::Subscription.valid_attr?(attr, p) }
          q.responses[:not_valid] = "This response is not valid for the '#{attr.to_s}' setting."
        }
        # Set cleared responses to nil
        if tgt_subscription.send(attr) == '-'
          tgt_subscription.send("#{attr.to_s}=".to_sym, nil)
        end
      end
      if save_subscription?
        config.set_subscription cfg_subscription
        config.save_to_disk!
      end
    end

    def ui_show_subscription
      table = Terminal::Table.new do |t|
        t.add_row ['Setting','Value']
        t.add_separator
        Installer::Subscription.object_attrs.each do |attr|
          value = merged_subscription.send(attr)
          if value.nil?
            value = '-'
          elsif attr == :rh_password
            value = '******'
          end
          t << [attr.to_s, value]
        end
      end
      ui_newpage
      say translate :subscription_summary
      puts table
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

    def ui_modify_dns
      new_dns = {}
      new_dns['app_domain'] = ask("\nWhat domain will be used for hosted applications? ") { |q|
        if deployment.dns.has_key?('app_domain')
          q.default = deployment.dns['app_domain']
        end
        q.validate = lambda { |p| is_valid_domain?(p) }
        q.responses[:not_valid] = "Enter a valid domain"
      }
      deployment.set_dns new_dns
      deployment.save_to_disk!
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
        host_instance.ssh_host = ask("Host name (for remote access): ") { |q|
          if not host_instance.ssh_host.nil?
            q.default = host_instance.ssh_host
          end
          q.validate = lambda { |p| is_valid_hostname_or_ip_addr?(p) }
          q.responses[:not_valid] = "Enter a valid hostname or IP address"
        }
        host_instance.host = ask("Host name (for other components in the subnet): ") { |q|
          if not host_instance.host.nil?
            q.default = host_instance.host
          elsif not host_instance.ssh_host.nil?
            q.default = host_instance.ssh_host
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
        host_instance.user = ask("OpenShift username on #{host_instance.ssh_host}: ") { |q|
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

    def list_dns
      puts "\nDNS Settings\n"
      if deployment.dns.has_key?('app_domain')
        puts "  * App Domain: #{deployment.dns['app_domain']}"
      else
        puts "  [Not set]"
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
        puts "  [None]\n"
      end
      list.length
    end

    def list_host_instance host_instance
      table = Terminal::Table.new do |t|
        Installer::HostInstance.attrs.each do |attr|
          value = host_instance.send(attr)
          if not value.nil?
            t.add_row [attr.to_s.split('_').map{ |word| ['db','ssh'].include?(word) ? word.upcase : word.capitalize}.join(' '), value]
          end
        end
      end
      puts table
    end

    def merged_subscription
      @merged_subscription = Installer::Subscription.new(config)
      Installer::Subscription.object_attrs.each do |attr|
        value = cli_subscription.send(attr)
        if value.nil?
          value = cfg_subscription.send(attr)
        end
        if not value.nil?
          @merged_subscription.send("#{attr.to_s}=".to_sym, value)
        end
      end
      @merged_subscription
    end
  end
end
