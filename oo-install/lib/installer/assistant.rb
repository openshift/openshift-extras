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

    attr_reader :workflow_id, :target_version
    attr_accessor :config, :deployment, :cli_subscription, :cfg_subscription, :workflow, :workflow_cfg

    def initialize config, workflow_id=nil, advanced_mode=false, cli_subscription=nil, target_version=nil
      @config = config
      @target_version = target_version
      @advanced_mode = advanced_mode
      @deployment = config.get_deployment
      @cfg_subscription = config.get_subscription
      @cli_subscription = cli_subscription
      @workflow_id = workflow_id
      @save_subscription = true
      # This is a bit hinky; highline/import shoves a HighLine object into the $terminal global
      # so we need to set these on the global object
      $terminal.wrap_at = 70
    end

    def run
      if workflow_id.nil?
        ui_welcome_screen
      else
        # Check the Deployment
        unless deployment.is_complete?
          puts translate :exit_incomplete_deployment
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
        @workflow = Installer::Workflow.find(workflow_id)
        @workflow_cfg = config.get_workflow_cfg(workflow_id)
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
          check_deployment
        end

        say "\n" + translate(:info_unattended_workflow_start)

        # Hand it off to the workflow executable
        workflow.executable.run workflow_cfg, merged_subscription, config.file_path
      end
      0
    end

    def workflow_cfg_complete?
      if workflow.nil? or (workflow.questions.length > 0 and (workflow_cfg.nil? or workflow_cfg.empty?))
        return false
      end
      workflow.questions.each do |q|
        if not workflow_cfg.has_key?(q.id) or not q.valid?(deployment, workflow_cfg[q.id])
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

    def advanced_mode?
      @advanced_mode
    end

    private
    def ui_title
      ui_newpage
      say translate(:title)
      say "#{horizontal_rule}\n\n"
    end

    def ui_newpage
      puts "\n"
    end

    def ui_welcome_screen
      ui_title
      say translate :welcome
      say translate :intro
      puts "\n"
      loop do
        choose do |menu|
          menu.header = translate :select_workflow
          menu.prompt = "#{translate(:menu_prompt)} "
          descriptions = ["\nInstallation Options:\n#{horizontal_rule}"]
          Installer::Workflow.list(get_context).each do |workflow|
            menu.choice(workflow.summary) { ui_workflow(workflow.id) }
            descriptions << "## #{workflow.summary}\n#{workflow.description}"
          end
          descriptions << horizontal_rule
          menu.hidden("?") { say descriptions.join("\n\n") + "\n\n" }
          menu.hidden("q") { return 0 }
        end
      end
    end

    def ui_workflow id
      @workflow = Installer::Workflow.find(id)
      @workflow_cfg = config.get_workflow_cfg(id)
      # If the user supplied a desired target version, set it here.
      if not target_version.nil?
        @workflow_cfg['version'] = target_version
      end
      ui_newpage

      # Deployment check
      if workflow.check_deployment?
        deployment_question = "\nDo you want to change the basic deployment info?"
        deployment_followup = "\nDo you want to go back and modify your basic deployment info settings?"
        if not deployment.is_complete?
          say translate :info_force_run_deployment_setup
          ui_edit_deployment
          ui_show_deployment
          deployment_question = deployment_followup
        else
          ui_show_deployment
        end
        while concur(deployment_question, translate(:help_basic_deployment))
          ui_edit_deployment
          ui_show_deployment
          deployment_question = deployment_followup
        end
      end

      # Subscription check
      ui_newpage
      if workflow.check_subscription?
        msub = merged_subscription
        sub_question = "\nDo you want to make any changes to the subscription info in the configuration file?"
        sub_followup = "\nDo you want to go back and modify your subscription info settings in the configuration file?"
        if not msub.is_complete? or not Installer::Subscription.valid_types_for_context.include?(msub.subscription_type.to_sym)
          ui_show_subscription(translate(:info_force_run_subscription_setup))
          puts "\n"
          @show_menu = true
          while @show_menu
            choose do |menu|
              menu.header = translate :select_subscription
              menu.prompt = "#{translate(:menu_prompt)} "
              menu.choice('Add subscription settings to the installer configuration file') { say "\nEditing installer subscription settings"; @show_menu = false }
              menu.choice('Enter subscription settings now without saving them to disk') { @save_subscription = false; say "\nGetting subscription settings for this installation"; @show_menu = false }
              menu.hidden("?") {
                say "\nSubscription Settings:"
                say "#{horizontal_rule}\n\n"
                say translate :explain_subscriptions
                say "\n#{horizontal_rule}\n\n"
              }
              menu.hidden("q") { return_to_main_menu }
            end
          end
          ui_edit_subscription
          sub_question = sub_followup
        end
        ui_show_subscription
        while concur(sub_question, translate(:help_subscription_cfg))
          @save_subscription = true
          ui_edit_subscription
          ui_show_subscription
          sub_question = sub_followup
        end
        subtemp_question = "\nDo you want to set any temporary subscription settings for this installation only?"
        subtemp_followup = "\nDo you want to go back and change any of the temporary subscription settings that you've set?"
        while concur(subtemp_question, translate(:help_subscription_tmp))
          @save_subscription = false
          ui_edit_subscription
          ui_show_subscription
          subtemp_question = subtemp_followup
        end
      end

      # Workflow questions
      if workflow.questions.length > 0
        ui_edit_workflow
      end

      # Workflow remote systems preflight
      if workflow.remote_execute?
        say "\nPreflight check: verifying system and resource availability."
        check_deployment
      end

      unless workflow.non_deployment?
        say "\nDeploying workflow '#{id}'."
      end

      # Hand it off to the workflow executable
      workflow.executable.run workflow_cfg, merged_subscription, config.file_path
      raise Installer::AssistantWorkflowCompletedException.new
    end

    def ui_edit_workflow
      if not workflow_cfg.empty?
        say "\nThese are your current settings for this workflow:"
        ui_show_workflow
      end
      while workflow_cfg.empty? or concur("\nDo you want to make any changes to your answers?", translate(:help_workflow_questions))
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
          if question.type.start_with?('rolehost')
            # Look up the host instance to show
            role = question.type.split(':')[1]
            say "Target system - " << deployment.find_host_instance_for_workflow(workflow_cfg[question.id], role).summarize
          else
            say "#{question.id.capitalize}: #{workflow_cfg[question.id]}"
          end
        end
      end
    end

    def ui_edit_deployment
      unless deployment.dns.keys.length > 0
        say "\n#{translate(:info_force_run_dns_setup)}"
        ui_modify_dns
      else
        list_dns
      end
      while concur("\nDo you want to change the DNS settings?", translate(:help_dns_settings))
        ui_modify_dns
      end
      Installer::Deployment.display_order.each do |role|
        if not advanced_mode? and [:mqserver, :dbserver].include?(role)
          next
        end
        hkey = Installer::Deployment.role_map[role]
        list_count = list_role role
        role_singular = hkey.chop
        role_list = role == :node ? "#{hkey} list" : role_singular
        if list_count == 0
          say "\nYou must add a #{role_singular}."
          ui_modify_role_list role
        end
        while not deployment.is_valid_role_list?(role) or concur("\nDo you want to modify the #{role_list}?", translate(:help_roles_edits))
          ui_modify_role_list role
        end
      end
      # In basic mode, the mqserver and dbserver host lists are cloned from the broker list
      if not advanced_mode?
        deployment.clone_broker_instances!
      end
    end

    def ui_show_deployment
      ui_newpage
      say translate :deployment_summary
      if not advanced_mode?
        say translate :basic_mode_explanation
      end
      Installer::Deployment.display_order.each do |role|
        if not advanced_mode? and [:mqserver, :dbserver].include?(role)
          next
        end
        list_role role
      end
      list_dns
    end

    def ui_edit_subscription
      ui_newpage
      tgt_subscription = save_subscription? ? cfg_subscription : cli_subscription
      valid_types = tgt_subscription.subscription_types
      valid_types_list = valid_types.keys.map{ |t| t.to_s }.join(', ')
      tgt_subscription.subscription_type = ask("What type of subscription should be used? (#{valid_types_list}) ") { |q|
        if not merged_subscription.subscription_type.nil? and valid_types.keys.include?(merged_subscription.subscription_type)
          q.default = merged_subscription.subscription_type
        end
        q.validate = lambda { |p| valid_types.keys.include?(p.to_sym) }
        q.responses[:not_valid] = "Valid subscription types are #{valid_types_list}"
      }.to_s
      type_settings = valid_types[tgt_subscription.subscription_type.to_sym]
      type_settings[:attr_order].each do |attr|
        if tgt_subscription.subscription_type == 'yum' and not workflow.repositories.empty? and not workflow.repositories.include?(attr)
          next
        end
        desc = type_settings[:attrs][attr]
        question = attr == :rh_password ? '<%= @key %>' : "#{desc}? "
        if save_subscription? or not [:rh_username, :rh_password].include?(attr)
          question << "(Use '-' to leave unset) "
        end
        tgt_subscription.send "#{attr.to_s}=".to_sym, ask(question) { |q|
          if not attr == :rh_password
            if not merged_subscription.send(attr).nil?
              q.default = merged_subscription.send(attr)
            elsif save_subscription? or not [:rh_username, :rh_password].include?(attr)
              q.default = '-'
            end
          end
          if attr == :rh_password
            q.echo = '*'
            q.verify_match = true
            q.gather = {
              "Red Hat Account password? " => '',
              "Type password again to verify: " => '',
            }
          end
          q.validate = lambda { |p| p == '-' or Installer::Subscription.valid_attr?(attr, p) }
          q.responses[:not_valid] = "This response is not valid for the '#{attr.to_s}' setting."
        }.to_s
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

    def ui_show_subscription(message=translate(:subscription_summary))
      mrg_subscription = merged_subscription
      values = mrg_subscription.to_hash
      type = '-'
      settings = nil
      show_settings = false
      if not values.empty? and Installer::Subscription.valid_types_for_context.include?(values['type'].to_sym)
        type = values['type']
        settings = mrg_subscription.subscription_types[type.to_sym]
        show_settings = true
      end
      table = Terminal::Table.new do |t|
        t.add_row ['Setting','Value']
        t.add_separator
        t.add_row ['type', type]
        if show_settings
          settings[:attr_order].each do |attr|
            # If this workflow specifies supported yum repositories, honor that list
            if type == 'yum' and not workflow.repositories.empty? and not workflow.repositories.include?(attr)
              next
            end
            key = attr.to_s
            value = values[key]
            if value.nil?
              value = '-'
            elsif attr == :rh_password
              value = '******'
            end
            t << [key, value]
          end
        end
      end
      ui_newpage
      say message
      puts table
    end

    def ui_modify_role_list role
      list = deployment.get_role_list(role)
      if list.length
        if role == :node
          say "\nModifying the " + Installer::Deployment.role_map[role] + " list.\n\n"
          choose do |menu|
            menu.header = "Select the number of the #{role.to_s} host instance that you wish to modify"
            menu.prompt = "#{translate(:menu_prompt)} "
            for i in 0..(list.length - 1)
              menu.choice(list[i].summarize) { ui_edit_host_instance list[i], list.length, i }
            end
            menu.choice("Add a new #{role.to_s}") { ui_edit_host_instance Installer::HostInstance.new(role) }
            menu.hidden("q") { return_to_main_menu }
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
      }.to_s
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
          menu.prompt = "#{translate(:menu_prompt)} "
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
          index = 0
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
        # Get the FQDN
        host_instance.host = ask("Hostname (for other OpenShift components in the same subnet): ") { |q|
          if not host_instance.host.nil?
            q.default = host_instance.host
          end
          q.validate = lambda { |p| is_valid_hostname?(p) }
          q.responses[:not_valid] = "Enter a valid hostname (FQDN or 'localhost')"
        }.to_s
        # Get login info if necessary
        if not host_instance.localhost?
          loop do
            host_instance.ssh_host = ask("Hostname / IP address for SSH access: ") { |q|
              if not host_instance.ssh_host.nil?
                q.default = host_instance.ssh_host
              elsif not host_instance.host.nil?
                q.default = host_instance.host
              end
              q.validate = lambda { |p| is_valid_hostname?(p) }
              q.responses[:not_valid] = "Enter a valid hostname"
            }.to_s
            host_instance.user = ask("Username for SSH access and installation: ") { |q|
              if not host_instance.user.nil?
                q.default = host_instance.user
              elsif get_context == :ose
                q.default = 'root'
              end
              q.validate = lambda { |p| is_valid_username?(p) }
              q.responses[:not_valid] = "Enter a valid linux username"
            }.to_s
            say "Validating #{host_instance.user}@#{host_instance.ssh_host}... "
            if host_instance.has_valid_access?
              say "looks good."
              break
            else
              say "\nCould not connect to #{host_instance.ssh_host} with user #{host_instance.user}. You must set up an SSH key pair and using ssh-agent is strongly recommended."
            end
          end
        else
          # For localhost, run with what we already have
          host_instance.ssh_host = host_instance.host
          host_instance.user = `whoami`.chomp
          ip_path = which('ip')
          if ip_path.nil?
            raise Installer::AssistantMissingUtilityException.new("Could not determine the location of the 'ip' utility for running 'ip addr list'. Exiting.")
          end
          host_instance.set_ip_exec_path(ip_path)
          say "Using current user (#{host_instance.user}) for local installation."
        end
        # Finally, set up the IP info for brokers and nodes.
        if host_instance.is_broker? or host_instance.is_node?
          ip_addrs = host_instance.get_ip_addr_choices
          case ip_addrs.length
          when 0
            say "Could not detect an IP address for this host."
            manual_ip_info_for_host_instance(host_instance, ip_addrs)
          when 1
            say "Detected IP address #{ip_addrs[0][1]} at interface #{ip_addrs[0][0]} for this host."
            question = "Do you want Nodes to use this IP information to reach this Broker?"
            if host_instance.is_node?
              question = "Do you want to use this as the public IP information for this Node?"
            end
            if concur(question, translate(:ip_config_help_text))
              host_instance.ip_addr = ip_addrs[0][1]
              if host_instance.is_node?
                host_instance.ip_interface = ip_addrs[0][0]
              end
            else
              manual_ip_info_for_host_instance(host_instance, ip_addrs)
            end
          else
            say "Detected multiple network interfaces for this host:"
            ip_addrs.each do |info|
              say "* #{info[1]} on interface #{info[0]}"
            end
            question = "Do you want Nodes to use one of these IP addresses to reach this Broker?"
            if host_instance.is_node?
              question = "Do you want to use one of these as the public IP information for this Node?"
            end
            if concur(question, translate(:ip_config_help_text))
              choose do |menu|
                menu.header = "The following network interfaces were found on this host. Choose the one that it uses for communication on the local subnet."
                menu.prompt = "#{translate(:menu_prompt)} "
                ip_addrs.each do |info|
                  ip_interface = info[0]
                  ip_addr = info[1]
                end
                menu.choice("#{ip_addr} on interface #{ip_interface}") { host_instance.ip_addr = ip_addr; host_instance.ip_interface = ip_interface if host_instance.is_node? }
              end
              menu.hidden("?") { say "The current host instance has mutliple IP options. Select the one that it will use to connect to other OpenShift components." }
              menu.hidden("q") { return_to_main_menu }
            else
              manual_ip_info_for_host_instance(host_instance, ip_addrs)
            end
          end
        end
        host_instance_is_valid = true
      end
    end

    def manual_ip_info_for_host_instance(host_instance, ip_addrs)
      addr_question = "\nSpecify the IP address that Nodes will use to connect to this Broker"
      if host_instance.is_node?
        addr_question = "\nSpecify the public IP address for this Node"
      end
      if ip_addrs.length > 0
        addr_question << " (Detected #{ip_addrs.map{ |i| i[1] }.join(', ')})"
      end
      addr_question << ": "
      host_instance.ip_addr = ask(addr_question) { |q|
        if not host_instance.ip_addr.nil?
          q.default = host_instance.ip_addr
        end
        q.validate = lambda { |p| is_valid_ip_addr?(p) }
        q.responses[:not_valid] = "Enter a valid IP address"
      }.to_s
      if [:origin,:origin_vm].include?(get_context) and host_instance.is_node?
        int_question = "Specify the network interface that this Node will use to route Application traffic"
        if ip_addrs.length > 0
          int_question << " (Detected #{ip_addrs.map{ |i| "'#{i[0]}'" }.join(', ')})"
        end
        int_question << ": "
        host_instance.ip_interface = ask(int_question) { |q|
          if not host_instance.ip_interface.nil?
            q.default = host_instance.ip_interface
          end
          q.validate = lambda { |p| is_valid_string?(p) }
          q.responses[:not_valid] = "Enter a valid IP interface ID"
        }.to_s
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
      list = deployment.get_role_list(role)
      header = role == :node && list.length > 1 ? Installer::Deployment.role_map[role] : Installer::Deployment.role_map[role].chop
      puts "\n#{header}\n"
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
          if value.nil?
            if attr == :ip_addr and host_instance.is_broker? or host_instance.is_node?
              value = "[unset - required]"
            elsif [:origin_vm,:origin].include?(get_context) and attr == :ip_interface and host_instance.is_node?
              value = "[unset - required]"
            else
              next
            end
          end
          t.add_row [attr.to_s.split('_').map{ |word| ['db','ssh','ip'].include?(word) ? word.upcase : word.capitalize}.join(' '), value]
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

    def concur(yes_or_no_question, help_text=nil)
      question_suffix = help_text.nil? ? ' (y/n/q) ' : ' (y/n/q/?) '
      full_help = help_text.nil? ? '' : "\n#{help_text}\n"
      full_help << "\nPlease press \"y\" or \"n\" to continue, or \"q\" to return to the main menu."
      response = ask("#{yes_or_no_question}#{question_suffix}") { |q|
        q.validate = lambda { |p| [?y,?n,?q].include?(p.downcase[0]) }
        q.responses[:not_valid] = full_help
        q.responses[:ask_on_error] = :question
        q.character = true
      }
      case response
      when 'y'
        return true
      when 'n'
        return false
      else
        return_to_main_menu
      end
    end

    def return_to_main_menu
      say "\nReturning to main menu."
      raise Installer::AssistantRestartException.new
    end

    def check_deployment
      deployment_good = true
      deployment.by_ssh_host.each_pair do |ssh_host,instance_list|
        test_host = instance_list[0]
        ssh_host_roles = instance_list.map{ |h| h.role }
        say "\nChecking #{test_host.host}:"
        # Attempt SSH connection for remote hosts
        if not test_host.localhost?
          begin
            test_host.get_ssh_session
          rescue Errno::ECONNREFUSED => e
            say "* SSH connection refused; check SSH settings"
            deployment_good = false
            # Don't bother to try the rest of the checks
            next
          end
          say "* SSH connection succeeded"
        end

        # Check the target host deployment type
        if workflow.targets[test_host.host_type].nil?
          if workflow.targets.keys.length == 1
            say "* Target host does not appear to be a #{supported_targets[workflow.targets.keys[0]]} system"
          else
            say "* Target host does not appear to be of these types: #{workflow.targets.map{ |t| supported_targets[t] }.join(', ')}"
          end
          deployment_good = false
          next
        else
          say "* Target host is running #{supported_targets[test_host.host_type]}"
        end

        # Check for all required utilities
        workflow.utilities.each do |util|
          check_on_role = :all
          if util.split(":").length == 2
            check_on_role = util.split(":")[0].to_sym
            util = util.split(":")[1]
          end
          if not check_on_role == :all and not ssh_host_roles.include?(check_on_role)
            next
          end
          cmd_result = {}
          if test_host.localhost?
            cmd_result[:exit_code] = which(util).nil? ? 1 : 0
          else
            cmd_result = test_host.exec_on_host!("command -v #{util}")
          end
          if not cmd_result[:exit_code] == 0
            say "* Could not locate #{util}... "
            find_result = test_host.exec_on_host!("yum -q provides */#{util}")
            if not find_result[:exit_code] == 0
              say "no suggestions available"
            else
              ui_suggest_rpms(find_result[:stdout])
            end
            deployment_good = false
          else
            if not test_host.root_user?
              say "* Located #{util}... "
              sudo_result = {}
              if test_host.localhost?
                sudo_result[:stdout] = which('sudo')
                sudo_result[:exit_code] = sudo_result[:stdout].nil? ? 1 : 0
              else
                sudo_result = test_host.exec_on_host!("command -v sudo")
              end
              if not sudo_result[:exit_code] == 0
                say "could not locate sudo"
                deployment_good = false
              else
                sudo_cmd_result = test_host.exec_on_host!("#{sudo_result[:stdout]} #{util} --version")
                if not sudo_cmd_result[:exit_code] == 0
                  say "could not invoke '#{util} --version' with sudo"
                  deployment_good = false
                else
                  say "invoked '#{util} --version' with sudo"
                end
              end
            else
              say "* Located #{util}"
            end
          end
        end

        if not test_host.localhost?
          begin
            # Close the ssh session
            test_host.close_ssh_session
          rescue Errno::ENETUNREACH
            say "* Could not reach host"
            deployment_good = false
          rescue Net::SSH::Exception, SocketError => e
            say "* #{e.message}"
            deployment_good = false
          end
        end
        if deployment_good == false
          raise Installer::DeploymentCheckFailedException.new
        end
      end
      if deployment_good == false
        raise Installer::DeploymentCheckFailedException.new
      end
    end

    def ui_suggest_rpms(yum_provides_text)
      # This titanic operation teases out package names from the `yum -q provides` output
      # The sort at the end puts packages in descending order, placing packages with a ':' to the end of the list
      yum_packages = yum_provides_text.split("\n").select{ |l| l.match(/^\w/) }.map{ |l| l.split(' ')[0] }.select{ |l| l.match(/\./) }.uniq.sort{ |a,b| (b <=> a if ((a.match(/:/) and b.match(/:/)) or (not a.match(/:/) and not b.match(/:/)))) || ((a.match(/:/) ? 1 : -1) <=> (b.match(/:/) ? 1 : -1)) }
      if yum_packages.length > 0
        say "try to `yum install` one of:"
        yum_packages.each do |pkg|
        say "  - #{pkg}"
      end
      else
        say "you will need to add a repository that provides this."
      end
    end
  end
end
