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

    attr_reader :workflow_id
    attr_accessor :config, :deployment, :cli_subscription, :cfg_subscription, :workflow, :workflow_cfg, :version_text

    def initialize config, deployment=nil, workflow_id=nil, cli_subscription=nil, version_text=nil
      @config = config
      @deployment = deployment || config.get_deployment
      @cfg_subscription = config.get_subscription
      @cli_subscription = cli_subscription
      @workflow_id = workflow_id
      @save_subscription = true
      @version_text = version_text
      # This is a bit hinky; highline/import shoves a HighLine object into the $terminal global
      # so we need to set these on the global object
      $terminal.wrap_at = 70
    end

    def run
      if workflow_id.nil?
        ui_welcome_screen
      else
        # Check the Deployment
        saw_errors = false
        say translate(:info_wait_configuration_validation)
        say "\n" + translate(:info_deployment_validation) + " "
        errors = deployment.is_valid?(:full)
        if errors.length > 0
          saw_errors = true
          say translate(:info_found_errors)
          errors.each do |e|
            say "\n* #{e.message}"
          end
        else
          say translate(:info_good_to_go)
        end

        # Check the Workflow settings
        @workflow = Installer::Workflow.find(workflow_id)
        @workflow_cfg = config.get_workflow_cfg(workflow_id)
        if workflow.questions.length > 0
          say "\n" + translate(:info_workflow_validation) + " "
          errors = workflow.is_valid_config?(workflow_cfg, deployment, :full)
          if errors.length > 0
            saw_errors = true
            say translate(:info_found_errors)
            errors.each do |e|
              say "\n* #{e.message}"
            end
          else
            say translate(:info_good_to_go)
          end
        end

        # Check the subscription info
        if workflow.check_subscription?
          say "\n" + translate(:info_subscription_validation) + " "
          errors = merged_subscription.is_valid?(:full)
          if errors.length > 0
            saw_errors = true
            say translate(:info_found_errors)
            errors.each do |e|
              say "\n* #{e.message}"
            end
          else
            say translate(:info_good_to_go)
          end
        end

        # If the config has problems, time to bail out.
        if saw_errors
          say "\n" + translate(:error_unattended_workflow_cfg)
          return 1
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


    def save_subscription?
      @save_subscription
    end

    private
    def ui_title
      title = translate(is_origin_vm? ? :vm_title : :title)
      if not version_text.nil? and not version_text.empty?
        title << " (#{version_text})"
      end
      say title
      say "#{horizontal_rule}\n\n"
    end

    def ui_newpage
      puts "\n"
    end

    def ui_welcome_screen
      ui_title
      say translate(is_origin_vm? ? :vm_welcome : :welcome)
      if is_origin_vm?
        say "\n\tHost: #{vm_installer_host.host}"
        say "\tUser: #{vm_installer_host.user}"
        say "\tPass: changeme"
        say "\t  IP: #{vm_installer_host.ip_addr}"
        puts "\n"
        if @config.new_config? and not @offered_tutorial and agree("It looks like this is your first time using the Origin VM. Would you like to take the administrator's tutorial? If you answer 'no', you can always go back to the main menu and select 'Take the Tutorial' to see it.\n\nTake the tutorial? (y/n) ", true)
          @offered_tutorial = true
          ui_workflow('vm_tutorial')
        else
          @offered_tutorial = true
          say "\n#{translate(:vm_intro)}"
        end
      else
        say "\n#{translate(:intro)}"
      end
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
          if is_origin_vm?
            menu.choice("Exit to the command prompt.") { say "\nTo restart the menu at any time, run 'oo-install'.\n\n"; return 0 }
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
      @workflow_id = id
      ui_newpage

      # Deployment check
      if workflow.check_deployment?
        if deployment.hosts.length == 0
          ui_create_deployment
          ui_show_deployment
          if concur("\nDo you want to change the deployment info?", translate(:help_basic_deployment))
            ui_edit_deployment
          end
        elsif not deployment.is_valid?
          ui_show_deployment(translate(:info_force_run_deployment_setup))
          ui_edit_deployment
        else
          ui_show_deployment
          if concur("\nDo you want to change the deployment info?", translate(:help_basic_deployment))
            ui_edit_deployment
          end
        end
      end

      # Subscription check
      if workflow.check_subscription?
        ui_newpage
        msub = merged_subscription
        sub_question = "\nDo you want to make any changes to the subscription info in the configuration file?"
        sub_followup = "\nDo you want to go back and modify your subscription info settings in the configuration file?"
        if not msub.is_valid? or not Installer::Subscription.valid_types_for_context.include?(msub.subscription_type)
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

      # Exit the workflow, and possibly the application.
      if not workflow.exit_on_complete?
        raise Installer::AssistantRestartException.new
      elsif workflow.non_deployment?
        raise Installer::AssistantWorkflowNonDeploymentCompletedException.new
      else
        raise Installer::AssistantWorkflowCompletedException.new
      end
    end

    def ui_create_deployment
      use_origin_vm_as_broker = false
      has_running_broker = false
      if is_origin_vm?
        say "Before we do that, we need to gather information about the Origin system that you want to deploy. It can consist of one or more hosts systems, including this VM. See:\n\nhttp://openshift.github.io/documentation/oo_install_users_guide.html\n\nfor information on how to integrate this VM into a larger OpenShift deployment."
        use_origin_vm_as_broker = concur("\n#{horizontal_rule}\nNOTE: Using this VM in a Full Deployment\n#{horizontal_rule}\nBe aware that if this VM is reconfigured as part of a larger deployment, you will potentially lose access to any applications that you have already built here. Additionally, this system will switch from mDNS to BIND, which means that you will need to do some DNS configuration in your own network to be able to connect to this VM by hostname.\n\nIf you answer 'no', we'll gather information about your intended Broker host in a moment.\n\nDo you want to use this VM as the Broker for a multi-host deployment?")
      else
        say "It looks like you are running oo-install for the first time on a new system. The installer will guide you through the process of defining your OpenShift deployment."
      end
      if not use_origin_vm_as_broker
        broker_question = is_origin_vm? ? 'Is there already a running Broker in the OpenShift system that you want to deploy?' : 'First things first: do you already have a running Broker?'
        has_running_broker = concur("\n#{broker_question}")
      else
        has_running_broker = true
      end
      if use_origin_vm_as_broker
        vm_hash = vm_installer_host.to_hash
        vm_hash['roles'] = ['broker']
        deployment.add_host_instance! Installer::HostInstance.new(vm_hash)
        say "\nOkay. This VM will be reconfigured as the Broker for a larger deployment."
      elsif has_running_broker
        say "\nOkay. We will collect information about your Broker in a moment."
      else
        say "\nOkay. We will gather information to install a Broker in a moment."
      end
      if not is_origin_vm?
        say "Before we do that, we need to collect some information about your OpenShift DNS configuration."
      end
      # Now grab the DNS config
      ui_modify_dns((has_running_broker and not use_origin_vm_as_broker))
      say "\nThat's all of the DNS information that we need right now. Next, we need to gather information about the hosts in your OpenShift deployment."
      Installer::Deployment.display_order.each do |role|
        role_item = Installer::Deployment.role_map[role].chop
        puts "\n" + horizontal_rule
        say "#{role_item} Configuration"
        puts horizontal_rule
        instance_exists = false
        if use_origin_vm_as_broker
          if role == :broker
            # We've already set up the Broker; move along.
            say "You've specified this Origin VM as the Broker for your new deployment. Now we'll gather information about where the other roles will be deployed."
            next
          end
        else
          instance_exists = role == :broker ? has_running_broker : concur("Do you already have a running #{role_item}?")
        end
        if instance_exists
          say "\nOkay. I'm going to need you to tell me about the host where the #{role_item} is installed."
        else
          say "\nOkay. I'm going to need you to tell me about the host where you want to install the #{role_item}."
        end
        create_host_instance = true
        if deployment.hosts.length > 0
          hosts_choice_help = "You have the option of installing more than one OpenShift role on a given host. If you would prefer to install the #{role_item} on a host that you haven't described yet, answer 'n' and you will be asked to provide details for that host instance."
          say "\nYou have already desribed the following host system(s):"
          deployment.hosts.each do |host_instance|
            say "* #{host_instance.summarize}"
          end
          if deployment.hosts.length == 1
            if concur("\nDo you want to assign the #{role_item} role to #{deployment.hosts[0].host}?", hosts_choice_help)
              say "\nOkay. Adding the #{role_item} role to #{deployment.hosts[0].host}."
              deployment.hosts[0].add_role(role)
              create_host_instance = false
            end
          else
            if concur("\nDo you want to assign the #{role_item} role to one of the hosts that you've already described?", hosts_choice_help)
              create_host_instance = false
              choose do |menu|
                menu.header = "\nWhich host would you like to assign this role to?"
                deployment.hosts.each do |host_instance|
                  menu.choice(host_instance.summarize) { say "Okay. Adding the #{role_item} role to #{host_instance.host}"; host_instance.add_role(role) }
                end
              end
            end
          end
        end
        if create_host_instance
          say "\nOkay, please provide information about the #{role_item} host." if deployment.hosts.length > 0
          ui_edit_host_instance(nil, role, 0, instance_exists)
        end
        if role == Installer::Deployment.display_order.last
          say "\nThat's everything we need to know right now for the #{role_item}."
        else
          say "\nThat's everything we need to know right now for the #{role_item}. Moving on to the next role."
        end
      end

      # In basic mode, the mqserver and dbserver host lists are cloned from the broker list
      if not advanced_mode?
        deployment.set_basic_hosts!
      end
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
            host_instance = deployment.get_host_instance_by_hostname(workflow_cfg[question.id])
            if host_instance.nil? or not host_instance.roles.include?(role.to_sym)
              say "Target system - [unset]"
            else
              say "Target system - " << host_instance.summarize
            end
          else
            say "#{question.id.capitalize}: #{workflow_cfg[question.id]}"
          end
        end
      end
    end

    def ui_edit_deployment
      # Force the configuration of anything that is missing
      resolved_issues = false
      if not deployment.dns.is_valid?
        resolved_issues = true
        say "\n#{translate(:info_force_run_dns_setup)}"
        ui_modify_dns
      end
      # Zip through the roles and make sure there is a host instance assigned to each.
      Installer::Deployment.display_order.each do |role|
        group_name = Installer::Deployment.role_map[role]
        group_item = group_name.chop
        group_list = Installer::Deployment.list_map[role]
        if deployment.send(group_list).length == 0
          resolved_issues = true
          say "\nYou must specify a #{group_item} host instance."
          ui_add_remove_host_by_role role
        end
      end
      # Zip through the hosts and make sure they are legit.
      first = true
      deployment.hosts.each do |host_instance|
        if not host_instance.is_valid?
          if first
            say "\nThe configuration file does not include some of the required settings for your primary host instance. Please provide this information below.\n\n"
          else
            say "\nThe configuration file does not include some of the required settings for host instance #{host_instance.host}. Please provide them here.\n\n"
          end
          edit_host_instance host_instance
          deployment.save_to_disk!
          resolved_issues = true
        end
        first = false
      end
      # Now show the current deployment and provide an edit menu
      exit_loop = false
      loop do
        if resolved_issues
          ui_show_deployment
        end
        node_choice = deployment.nodes.length > 1 ? "Add or remove a Node host" : "Add another Node host"
        choose do |menu|
          menu.header = "\nChoose from the following deployment configuration options"
          menu.prompt = "#{translate(:menu_prompt)} "
          menu.choice("Change the DNS configuration") { ui_modify_dns }
          menu.choice("Move an OpenShift role to a different host") { ui_move_role }
          menu.choice("Modify the information for an existing host") { ui_modify_host }
          menu.choice(node_choice) { ui_add_remove_host_by_role :node }
          menu.choice("Finish editing the deployment configuration") { exit_loop = true }
          menu.hidden("q") { return_to_main_menu }
        end
        if exit_loop
          break
        end
        resolved_issues = true
      end
      # In basic mode, the mqserver and dbserver host lists are cloned from the broker list
      if not advanced_mode?
        deployment.set_basic_hosts!
      end
    end

    def ui_show_deployment(message=translate(:deployment_summary))
      ui_newpage
      say message
      if not is_origin_vm? and not advanced_mode?
        say "\n#{translate(:basic_mode_explanation)}"
      end
      list_dns
      say "\nRole Assignments"
      list_role_host_map
      say "\nHost Information"
      deployment.hosts.each do |host_instance|
        list_host_instance host_instance
      end
    end

    def ui_edit_subscription
      ui_newpage
      tgt_subscription = save_subscription? ? cfg_subscription : cli_subscription
      valid_types = Installer::Subscription.valid_types_for_context
      valid_types_list = valid_types.map{ |t| t.to_s }.join(', ')
      tgt_subscription.subscription_type = ask("What type of subscription should be used? (#{valid_types_list}) ") { |q|
        if not merged_subscription.subscription_type.nil? and valid_types.include?(merged_subscription.subscription_type)
          q.default = merged_subscription.subscription_type.to_s
        end
        q.validate = lambda { |p| valid_types.include?(p.to_sym) }
        q.responses[:not_valid] = "Valid subscription types are #{valid_types_list}"
      }.to_sym
      type_settings = Installer::Subscription.subscription_info(tgt_subscription.subscription_type)
      type_settings[:attr_order].each do |attr|
        if tgt_subscription.subscription_type == :yum and not workflow.repositories.empty? and not workflow.repositories.include?(attr)
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
        settings = Installer::Subscription.subscription_info(mrg_subscription.subscription_type)
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
      say message
      puts table
    end

    def ui_modify_host
      if deployment.hosts.length == 1
        ui_edit_host_instance deployment.hosts[0]
      else
        choose do |menu|
          menu.header = "\nSelect a host instance to modify"
          menu.prompt = "#{translate(:menu_prompt)} "
          deployment.hosts.each do |host_instance|
            menu.choice(host_instance.summarize) { ui_edit_host_instance host_instance }
          end
          menu.hidden("q") { return_to_main_menu }
        end
      end
    end

    def ui_modify_dns(has_running_broker=false)
      question_text = has_running_broker ? 'What domain is being used for applications that are hosted by the OpenShift deployment?' : 'What domain do you want to use for applications that are hosted by this OpenShift deployment?'
      deployment.dns.app_domain = ask("\n#{question_text} ") { |q|
        if not deployment.dns.app_domain.nil?
          q.default = deployment.dns.app_domain
        end
        q.validate = lambda { |p| is_valid_domain?(p) }
        q.responses[:not_valid] = "Enter a valid domain"
      }.to_s
      question_text = has_running_broker ? 'Does the OpenShift DNS server include records for the OpenShift hosts themselves? Enter \'n\' if you don\'t know.' : 'Do you want to register DNS entries for your OpenShift hosts with the same OpenShift DNS service that will be managing DNS records for the hosted applications?'
      deployment.dns.register_components = concur("\n#{question_text}")
      if deployment.dns.register_components?
        loop do
          question_text = has_running_broker ? 'What domain do the OpenShift hosts reside in? ' : 'What domain do you want to use for the OpenShift hosts?'
          deployment.dns.component_domain = ask("\n#{question_text} ") { |q|
            if not deployment.dns.component_domain.nil?
              q.default = deployment.dns.component_domain
            end
            q.validate = lambda { |p| is_valid_domain?(p) }
            q.responses[:not_valid] = "Enter a valid domain"
          }.to_s
          if not has_running_broker and deployment.dns.app_domain == deployment.dns.component_domain
            break if concur("\nYou have specified the same domain for your applications and your OpenShift components. Do you wish to keep these settings?")
          else
            break
          end
        end
      else
        deployment.dns.component_domain = nil
      end
      deployment.save_to_disk!
    end

    def ui_add_remove_host_by_role role
      role_list = deployment.send(Installer::Deployment.list_map[role])
      target_list = deployment.hosts.select{ |h| not h.roles.include?(role) }
      group_name = Installer::Deployment.role_map[role]
      if role_list.length < 2 and target_list.length == 0
        ui_edit_host_instance(nil, role)
      else
        deletable_list = role_list.length == 1 ? [] : role_list.select{ |h| h.roles.length == 1 }
        non_deletable_list = role_list.select{ |h| h.roles.length > 1 }
        if deletable_list.length == 0 and target_list.length == 0
          say "Currently you cannot delete any #{group_name} because they are all sharing hosts with other OpenShift components. Move the other roles to different hosts and then you will be able to delete them."
          if concur("Do you want to add a new #{group_name.chop}?")
            ui_edit_host_instance(nil, role)
          end
        else
          header = "\nAdd a new host, add the role to an existing host, or choose one to remove"
          if deletable_list.length == 0
            header = "\nAdd a new host or add the #{group_name.chop} role to another existing host"
          elsif target_list.length == 0
            header = "\nAdd a new host or choose one to remove"
          end
          if non_deletable_list.length > 0
            addendum = ".\nNote that the following hosts cannot be deleted because they are configured for other roles as well:\n\n"
            non_deletable_list.each do |host_instance|
              addendum << "* #{host_instance.summarize}\n"
            end
            addendum << "\nMove the other roles to different hosts and then you will be able to delete them.\n\nChoose an action"
            header << addendum
          end
          choose do |menu|
            menu.header = header
            menu.prompt = "#{translate(:menu_prompt)} "
            menu.choice("Add a new host") { ui_edit_host_instance(nil, role) }
            target_list.each do |host_instance|
              menu.choice("Add role to #{host_instance.host}") {
                host_instance.add_role(role)
                deployment.save_to_disk!
                say "\nAdded #{role.to_s} role to #{host_instance.host}"
              }
            end
            deletable_list.each do |host_instance|
              menu.choice("Remove #{host_instance.host}") {
                deployment.remove_host_instance!(host_instance)
                say "\nRemoved #{host_instance.host}"
              }
            end
            menu.hidden("q") { return_to_main_menu }
          end
        end
      end
    end

    def ui_move_role
      move_role = nil
      choose do |menu|
        menu.header = "\nWhich role do you want to move to a different host?"
        menu.prompt = "#{translate(:menu_prompt)} "
        Installer::Deployment.display_order.each do |role|
          group = Installer::Deployment.role_map[role]
          menu.choice(group.chop) { move_role = role }
        end
        menu.hidden("q") { return_to_main_menu }
      end
      source_list = deployment.send(Installer::Deployment.list_map[move_role])
      source_host = nil
      if source_list.length > 1
        choose do |menu|
          menu.header = "\nWhich host should no longer include the role?"
          menu.prompt = "#{translate(:menu_prompt)} "
          source_list.each do |host_instance|
            menu.choice(host_instance.summarize) { source_host = host_instance }
          end
          menu.hidden("q") { return_to_main_menu }
        end
      else
        source_host = source_list[0]
      end
      # Figure out if any currently existing host instances could be a new landing place.
      target_hosts = deployment.hosts.select{ |h| not h.roles.include?(move_role) }
      if target_hosts.length > 0
        choose do |menu|
          menu.header = "\nSelect a host to use for this role:"
          menu.prompt = "#{translate(:menu_prompt)} "
          target_hosts.each do |host_instance|
            menu.choice(host_instance.summarize) {
              if remove_role(source_host, move_role)
                host_instance.add_role(move_role)
                deployment.save_to_disk!
              end
            }
          end
          menu.choice("Create a new host") { source_host.remove_role(move_role); ui_edit_host_instance(nil, move_role) }
          menu.hidden("q") { return_to_main_menu }
        end
      else
        source_host.remove_role(move_role)
        ui_edit_host_instance(nil, move_role)
      end
    end

    def remove_role source_host, role
      if source_host.roles.length == 1
        if concur("\nThe #{role.to_s} role was the only one assigned to host #{source_host.host}. If you move the role, this host will be removed from the deployment. Is it okay to proceed?")
          say "\nOkay; removing host #{source_host.host}."
          deployment.remove_host_instance!(source_host)
          return true
        else
          say "\nOkay; cancelling role move."
          return false
        end
      elsif source_host.roles.length > 1
        source_host.remove_role(role)
        return true
      end
      true
    end

    def ui_edit_host_instance(host_instance=nil, role_focus=nil, role_count=0, is_installed=false)
      puts "\n"
      new_host = host_instance.nil?
      if new_host
        host_instance = Installer::HostInstance.new({}, role_focus)
        host_instance.install_status = is_installed ? :completed : :new
      else
        say "Modifying host #{host_instance.host}"
      end
      if role_focus == :node and role_count > 1 and host_instance.roles.count == 1
        # If this host instance is Node-only
        choose do |menu|
          menu.header = "You have defined multiple Node hosts. Do you want to delete this host or update it?"
          menu.prompt = "#{translate(:menu_prompt)} "
          menu.choice("Update it") {
            edit_host_instance host_instance
            deployment.save_to_disk!
            say "Updated the #{rolename} host instance."
          }
          menu.choice("Delete it") {
            deployment.remove_host_instance! host_instance
            say "Deleted the #{rolename} host instance."
          }
        end
      else
        edit_host_instance host_instance
        if new_host
          deployment.add_host_instance! host_instance
        else
          deployment.save_to_disk!
        end
      end
    end

    def edit_host_instance host_instance
      host_instance_is_valid = false
      while not host_instance_is_valid
        first_pass = true
        loop do
          # Get the FQDN
          question_text = first_pass ? 'Hostname (the FQDN that other OpenShift hosts will use to connect to the host that you are describing):' : "\nPlease enter a valid hostname:"
          first_pass = false
          host_instance.host = ask("#{question_text} ") { |q|
            if not host_instance.host.nil?
              q.default = host_instance.host
            end
            q.validate = lambda { |p| is_valid_hostname?(p) and not p == 'localhost' }
            q.responses[:not_valid] = "Enter a valid fully-qualified domain name. 'localhost' is not valid here."
          }.to_s
          if not deployment.dns.component_domain.nil?
            if not host_instance.host.match(/\./)
              say "Appending component domain '#{deployment.dns.component_domain}' to hostname."
              host_instance.host = host_instance.host + "." + deployment.dns.component_domain
              break
            elsif not host_instance.host.match(/#{deployment.dns.component_domain}$/)
              say "\nThe hostname #{host_instance.host} is not part of the domain that was specified for OpenShift hosts (#{deployment.dns.component_domain})."
              host_instance.host = nil
            else
              break
            end
          else
            break
          end
        end
        # Get login info if necessary
        proceed_though_unreachable = false
        loop do
          host_instance.ssh_host = ask("\nHostname / IP address for SSH access to #{host_instance.host} from the host where you are running oo-install. You can say 'localhost' if you are running oo-install from the system that you are describing: ") { |q|
            if not host_instance.ssh_host.nil?
              q.default = host_instance.ssh_host
            elsif not host_instance.host.nil?
              q.default = host_instance.host
            end
            q.validate = lambda { |p| is_valid_hostname?(p) or is_valid_ip_addr?(p) }
            q.responses[:not_valid] = "Enter a valid hostname, SSH alias or IP address. 'localhost' is valid here."
          }.to_s
          if not host_instance.localhost?
            host_instance.user = ask("\nUsername for SSH access to #{host_instance.ssh_host}: ") { |q|
              if not host_instance.user.nil?
                q.default = host_instance.user
              elsif get_context == :ose
                q.default = 'root'
              end
              q.validate = lambda { |p| is_valid_username?(p) }
              q.responses[:not_valid] = "Enter a valid linux username"
            }.to_s
            say "\nValidating #{host_instance.user}@#{host_instance.ssh_host}... "
            ssh_access_info = host_instance.confirm_access
            if ssh_access_info[:valid_access]
              say "looks good."
              break
            else
              say "\nCould not connect to #{host_instance.ssh_host} with user #{host_instance.user}."
              if not ssh_access_info[:error].nil?
                say "The SSH attempt yielded the following error:\n\"#{ssh_access_info[:error].message}\""
              end
              if concur("\nDo you want to use this host configuration even though #{host_instance.host} could not be contacted?")
                proceed_though_unreachable = true
                break
              end
            end
          else
            # For localhost, run with what we already have
            host_instance.user = `whoami`.chomp
            ip_path = which('ip')
            if ip_path.nil?
              raise Installer::AssistantMissingUtilityException.new("Could not determine the location of the 'ip' utility for running 'ip addr list'. Exiting.")
            end
            host_instance.set_ip_exec_path(ip_path)
            say "Using current user (#{host_instance.user}) for local installation."
            break
          end
        end
        # Set up the IP info
        if proceed_though_unreachable
          manual_ip_info_for_host_instance(host_instance, [])
        else
          ip_addrs = host_instance.get_ip_addr_choices
          case ip_addrs.length
          when 0
            say "Could not detect an IP address for this host."
            manual_ip_info_for_host_instance(host_instance, ip_addrs)
          when 1
            say "\nDetected IP address #{ip_addrs[0][1]} at interface #{ip_addrs[0][0]} for this host."
            question = "Do you want Nodes to use this IP information to reach this host?"
            if host_instance.is_node?
              question = "Do you want to use this as the public IP information for this Node?"
            end
            if concur(question, translate(:ip_config_help_text))
              host_instance.ip_addr = ip_addrs[0][1]
              host_instance.ip_interface = ip_addrs[0][0]
            else
              manual_ip_info_for_host_instance(host_instance, ip_addrs)
            end
          else
            say "\nDetected multiple network interfaces for this host:"
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
                  menu.choice("#{ip_addr} on interface #{ip_interface}") { host_instance.ip_addr = ip_addr; host_instance.ip_interface = ip_interface if host_instance.is_node? }
                end
                menu.hidden("?") { say "The current host instance has mutliple IP options. Select the one that it will use to connect to other OpenShift components." }
                menu.hidden("q") { return_to_main_menu }
              end
            else
              manual_ip_info_for_host_instance(host_instance, ip_addrs)
            end
          end
        end
        # Optionally allow the user to set a distinct named_ip_addr for their broker.
        if host_instance.is_broker?
          host_instance.named_ip_addr = ask("\nNormally, the BIND DNS server that is installed on this Broker will be reachable from other OpenShift components using the Broker's configured IP address (#{host_instance.ip_addr}).\n\nIf that will work in your deployment, press <enter> to accept the default value. Otherwise, provide an alternate IP address that will enable other OpenShift components to reach the BIND DNS service on the Broker: ") { |q|
            q.default = host_instance.ip_addr
            q.validate = lambda { |p| is_valid_ip_addr?(p) }
            q.responses[:not_valid] = "Enter a valid IP address for the BIND DNS service"
          }.to_s
        end
        host_instance_is_valid = true
      end
    end

    def manual_ip_info_for_host_instance(host_instance, ip_addrs)
      addr_question = "\nSpecify the IP address that Nodes will use to connect to this host"
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
      say "\nDNS Settings\n"
      say "  * App Domain: #{deployment.dns.app_domain || '[unset]'}"
      say "  * Register OpenShift components with OpenShift DNS? "
      case deployment.dns.register_components
      when nil
        say "[unset]"
      when true
        say "Yes"
      when false
        say "No"
      end
      if not deployment.dns.component_domain.nil?
        say "  * Component Domain: #{deployment.dns.component_domain}"
      end
    end

    def list_role_host_map
      table = Terminal::Table.new do |t|
        Installer::Deployment.display_order.each do |role|
          hosts = deployment.hosts.select{ |h| h.roles.include?(role) }.map{ |h| h.host }
          role_title = Installer::Deployment.role_map[role]
          if hosts.length == 1
            role_title = role_title.chop
          elsif hosts.length == 0
            hosts << '-'
          end
          t.add_row [role_title, hosts.join("\n")]
        end
      end
      puts table
    end

    def list_host_instance host_instance
      table = Terminal::Table.new do |t|
        Installer::HostInstance.attrs.each do |attr|
          value = host_instance.send(attr)
          if value.nil?
            if attr == :ip_addr
              value = "[unset]"
            elsif [:origin_vm,:origin].include?(get_context) and attr == :ip_interface and host_instance.is_node?
              value = "[unset]"
            else
              next
            end
          end
          if attr == :roles
            has_roles = []
            Installer::Deployment.display_order.each do |role|
              if host_instance.roles.include?(role)
                has_roles << Installer::Deployment.role_map[role].chop
              end
            end
            value = has_roles.length > 0 ? has_roles.join(', ') : '[unset]'
          end
          if attr == :named_ip_addr
            t.add_row ['BIND DNS Addr', value]
          else
            t.add_row [attr.to_s.split('_').map{ |word| ['db','ssh','ip'].include?(word) ? word.upcase : word.capitalize }.join(' '), value]
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

    def concur(yes_or_no_question, help_text=nil)
      question_suffix = help_text.nil? ? ' (y/n/q) ' : ' (y/n/q/?) '
      full_help = help_text.nil? ? '' : "\n#{help_text}\n"
      full_help << "\nPlease press \"y\" or \"n\" to continue, or \"q\" to return to the main menu."
      response = ask("#{yes_or_no_question}#{question_suffix}") { |q|
        q.validate = lambda { |p| [?y,?n,?q].include?(p.downcase[0]) }
        q.responses[:not_valid] = full_help
        q.responses[:ask_on_error] = :question
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
      deployment.hosts.each do |host_instance|
        # If this is an "Add a Node deployment", skip checks for all standalone
        # nodes that are not the one being added.
        next if (
          ['origin_add_node','enterprise_add_node'].include?(@workflow_id) and
          workflow_cfg.has_key?('rolehost') and
          host_instance.is_basic_node? and
          not host_instance.host == workflow_cfg['rolehost']
        )
        say "\nChecking #{host_instance.host}:"
        # Attempt SSH connection for remote hosts
        if not host_instance.localhost?
          ssh_access_info = host_instance.confirm_access
          if not ssh_access_info[:valid_access]
            text = "* SSH connection could not be established"
            if not ssh_access_info[:error].nil?
              text << ":\n  \"#{ssh_access_info[:error].message}\""
            else
              text << "."
            end
            say text
            deployment_good = false
            # Don't bother to try the rest of the checks
            next
          end
          say "* SSH connection succeeded"
        end

        # Check the target host deployment type
        if workflow.targets[host_instance.host_type].nil?
          if workflow.targets.keys.length == 1
            say "* Target host does not appear to be a #{supported_targets[workflow.targets.keys[0]]} system"
          else
            say "* Target host does not appear to be of these types: #{workflow.targets.map{ |t| supported_targets[t] }.join(', ')}"
          end
          deployment_good = false
          next
        else
          say "* Target host is running #{supported_targets[host_instance.host_type]}"
        end

        # Check for all required components
        workflow.components.each do |component|
          incompatible = false
          check_on_role = :all
          check_on_type = :all
          repo = nil
          util = nil
          pkg = nil
          sub_util = nil

          # Figure out the kind of check we're doing
          component_info = component.split(":")
          incompatible = component_info[0] == 'incompatible' ? true : false
          check_type = component_info[1].to_sym
          role_or_type = component_info[2].to_sym
          if not role_or_type == :all
            if supported_targets.has_key?(role_or_type)
              check_on_type = role_or_type
            elsif Installer::Deployment.role_map.has_key?(role_or_type)
              check_on_role = role_or_type
            end
          end

          # Move along if this host doesn't match the role / type relevant to the test
          if (not check_on_role == :all and not host_instance.roles.include?(check_on_role)) or
            (not check_on_type == :all and not host_instance.host_type == check_on_type)
            next
          end

          # Set check values based on check type
          if check_type == :util
            util = component_info[3]
            sub_util = component_info[4]
          elsif check_type == :repo
            repo = component_info[3]
          elsif check_type == :pkg
            pkg = component_info[3]
          end

          # Handle repo checks
          if not repo.nil?
            repo_cmd = "yum repolist"
            cmd_result = host_instance.exec_on_host!(repo_cmd)
            if not cmd_result[:exit_code] == 0
              say "* ERROR: Could not perform repo check for #{repo}. Try running `#{repo_cmd}` manually to troubleshoot."
              deployment_good = false
            elsif not cmd_result[:stdout].match(/#{repo}/)
              if not incompatible
                say "* ERROR: The '#{repo}' repository isn't available via yum. Install / enable this repository and try again."
                deployment_good = false
              end
            else
              if not incompatible
                say "* #{repo} repository is present and enabled"
              else
                say "* ERROR: The '#{repo}' repository is enabled on this host. OpenShift has known incompatibility issues with it, so please disable it and then rerun the installer."
                deployment_good = false
              end
            end
            next
          end

          if not pkg.nil?
            pkg_cmd = "yum list installed | grep #{pkg}"
            cmd_result = host_instance.exec_on_host!(pkg_cmd)
            if not cmd_result[:exit_code] == 0
              if not incompatible
                say "* ERROR: Could not perform package check for #{pkg}. Try running `#{pkg_cmd}` manually to troubleshoot."
                deployment_good = false
              end
            elsif not cmd_result[:stdout].match(/#{pkg}/)
              if not incompatible
                say "* ERROR: The '#{pkg}' package is not installed on this host. Try running `yum install #{pkg}` and then try again."
                deployment_good = false
              end
            else
              if not incompatible
                say "* #{repo} repository is present and enabled"
              else
                say "* ERROR: The '#{pkg}' package is installed on this host. OpenShift has known incompatibility issues with it, so please remove it (`yum remove #{pkg}`) and then rerun the installer."
                deployment_good = false
              end
            end
            next
          end

          # Still here? Handle util checks
          cmd_result = {}
          if host_instance.localhost?
            cmd_result[:exit_code] = which(util).nil? ? 1 : 0
          else
            cmd_result = host_instance.exec_on_host!("command -v #{util}")
          end
          if not cmd_result[:exit_code] == 0
            if not incompatible
              say "* ERROR: Could not locate #{util}... "
              find_result = host_instance.exec_on_host!("yum -q provides */#{util}")
              if not find_result[:exit_code] == 0
                say "no suggestions available"
              else
                ui_suggest_rpms(find_result[:stdout])
              end
              deployment_good = false
            end
          else
            if incompatible
              say "* ERROR: The #{util} utility is installed on this host. OpenShift has known incompatibility issues with it, so please remove it and then rerun the installer."
              deployment_good = false
            else
              if not host_instance.root_user?
                say "* Located #{util}... "
                if not host_instance.can_sudo_execute?(util)
                  say "ERROR - cannot not invoke '#{util}' with sudo"
                  deployment_good = false
                else
                  say "can invoke '#{util}' with sudo"
                end
              else
                say "* Located #{util}"
              end
            end
          end
          # SELinux configuration check
          if util == 'getenforce'
            cmd_result = host_instance.exec_on_host!("#{util}")
            if not cmd_result[:exit_code] == 0
              say "* ERROR: Could not run #{util} to determine SELinux status."
              deployment_good = false
            elsif cmd_result[:stdout].chomp.strip.downcase == 'disabled'
              say "* ERROR: SELinux is disabled. You must enable SELinux on this host."
              deployment_good = false
            else
              say "* SELinux is running in #{cmd_result[:stdout].chomp.strip.downcase} mode"
            end
          end
          # SCL collection check
          if util == 'scl' and not sub_util.nil?
            cmd_result = host_instance.exec_on_host!("scl -l | grep #{sub_util}")
            if not cmd_result[:exit_code] == 0
              say "* ERROR: Could not run #{util} to determine presence of #{sub_util} collection."
              deployment_good = false
            elsif not cmd_result[:stdout].chomp.strip.downcase.match(/#{sub_util}/)
              say "* ERROR: The #{sub_util} software collection is not installed. Correct this by running `yum install #{sub_util}` on this system."
              deployment_good = false
            else
              say "* The #{sub_util} software collection is installed."
            end
          end
        end

        if not host_instance.localhost?
          begin
            # Close the ssh session
            host_instance.close_ssh_session
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
