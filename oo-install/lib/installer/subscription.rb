require 'installer/helpers'

module Installer
  class Subscription
    include Installer::Helpers

    @extra_repo_attrs = [:ose_repo_base, :rhel_extra_repo, :jbosseap_extra_repo,
                         :jbossews_extra_repo, :rhscl_extra_repo, :ose_extra_repo]
    @repo_attrs = [:repos_base, :jenkins_repo_base, :scl_repo,
                   :os_repo, :os_optional_repo, :puppet_repo_rpm, :cdn_repo_base,
                   :rhel_repo, :jboss_repo_base, :rhscl_repo_base].concat(@extra_repo_attrs)
    @object_attrs = [:subscription_type, :rh_username, :rh_password, :sm_reg_pool,
                     :rhn_reg_actkey].concat(@repo_attrs)

    attr_reader :config, :type
    attr_accessor *@object_attrs

    class << self
      def object_attrs
        @object_attrs
      end

      def repo_attrs
        @repo_attrs
      end

      def extra_repo_attrs
        @extra_repo_attrs
      end

      def extra_attr_info
        return {
          :ose_repo_base => 'The base URL for the OpenShift yum repositories ((ends in /6Server/x86_64/))',
          :rhel_extra_repo => 'Additional base RHEL channel (Useful for testing pre-release content)',
          :jbosseap_extra_repo => 'Additional JBossEAP channel (Useful for testing pre-release content)',
          :jbossews_extra_repo => 'Additional JBossEWS channel (Useful for testing pre-release content)',
          :rhscl_extra_repo => 'Additional SCL channel (Useful for testing pre-release content)',
          :ose_extra_repo => 'Additional OSE channel (Useful for testing pre-release content)',
        }
      end

      def subscription_info(type)
        case type
        when :none
          return {
            :desc => 'No subscription necessary',
            :attrs => {},
            :attr_order => [],
          }
        when :yum
          sub_info = {
            :desc => 'Get packages from yum and do not use a subscription',
            :attrs => {
              :cdn_repo_base => 'Default base URL for all repositories (uses the CDN layout)',
              :repos_base => 'The base URL for the OpenShift repositories',
              :ose_repo_base => 'The base URL for the OpenShift yum repositories ((ends in /6Server/x86_64/))',
              :jboss_repo_base => 'The base URL for the JBoss repositories (ends in /6Server/x86_64)',
              :jenkins_repo_base => 'The base URL for a Jenkins repository',
              :scl_repo => 'The base URL for an SCL repository',
              :rhscl_repo_base => 'The base URL for the SCL repositories (ends in /6Server/x86_64)',
              :os_repo => 'The URL of a yum repository for the operating system',
              :rhel_repo => 'The URL for a RHEL 6 repository (ends in /6Server/x86_64/os/)',
              :os_optional_repo => 'The URL for an "Optional" repository for the operating system',
              :puppet_repo_rpm => 'The URL for a Puppet Labs repository RPM',
           },
            :attr_order => repo_attrs,
          }
          sub_info[:attrs].merge!(extra_attr_info)
          return sub_info
        when :rhsm
          sub_info = {
            :desc => 'Use Red Hat Subscription Manager',
            :attrs => {
              :rh_username => 'Red Hat Login username',
              :rh_password => 'Red Hat Login password',
              :sm_reg_pool => 'Pool ID(s) to subscribe',
            },
            :attr_order => [:rh_username,:rh_password,:sm_reg_pool],
          }
          if advanced_repo_config?
            sub_info[:attrs].merge!(extra_attr_info)
            sub_info[:attr_order].concat(extra_repo_attrs)
          end
          return sub_info
        when :rhn
          sub_info = {
            :desc => 'Use Red Hat Network',
            :attrs => {
              :rh_username => 'Red Hat Login username',
              :rh_password => 'Red Hat Login password',
              :rhn_reg_actkey => 'RHN account activation key',
            },
            :attr_order => [:rh_username,:rh_password,:rhn_reg_actkey],
          }
          if advanced_repo_config?
            sub_info[:attrs].merge!(extra_attr_info)
            sub_info[:attr_order].concat(extra_repo_attrs)
          end
          return sub_info
        else
          raise Installer::SubscriptionTypeNotRecognizedException.new("Subscription type '#{type}' is not recognized.")
        end
      end

      def valid_attr? attr, value, check=:basic
        errors = []
        if attr == :subscription_type
          begin
            subscription_info(value)
          rescue Installer::SubscriptionTypeNotRecognizedException => e
            if check == :basic
              return false
            else
              errors << e
            end
          end
        elsif not attr == :subscription_type and not value.nil?
          # We have to be pretty flexible here, so we basically just format-check the non-nil values.
          if (@repo_attrs.include?(attr) and not is_valid_url?(value)) or
             ([:rh_username, :rh_password, :sm_reg_pool, :rhn_reg_actkey].include?(attr) and not is_valid_string?(value))
            return false if check == :basic
            errors << Installer::SubscriptionSettingNotValidException.new("Subscription setting '#{attr.to_s}' has invalid value '#{value}'.")
          end
        end
        return true if check == :basic
        errors
      end

      def valid_types_for_context
        case get_context
        when :origin, :origin_vm
          return [:none,:yum]
        when :ose
          return [:none,:yum,:rhsm,:rhn]
        else
          raise Installer::UnrecognizedContextException.new("Installer context '#{get_context}' is not supported.")
        end
      end
    end

    def initialize config, subscription={}
      @config = config
      self.class.object_attrs.each do |attr|
        attr_str = attr == :subscription_type ? 'type' : attr.to_s
        if subscription.has_key?(attr_str)
          value = attr == :subscription_type ? subscription[attr_str].to_sym : subscription[attr_str]
          self.send("#{attr.to_s}=".to_sym, value)
        end
      end
    end

    def is_advanced?
      self.class.subscription_info(subscription_type)[:attrs].each_key do |attr|
        if self.class.extra_repo_attrs.include?(attr) and !self.send(attr).nil?
          return true
        end
      end
      return advanced_repo_config?
    end

    def subscription_types
      @subscription_types ||=
        begin
          type_map = {}
          self.class.valid_types_for_context.each do |type|
            type_map[type] = self.class.subscription_info(type)
          end
          type_map
        end
    end

    def is_valid?(check=:basic)
      errors = []
      if subscription_type.nil?
        return false if check == :basic
        errors << Installer::SubscriptionSettingMissingException.new("The subscription type value is missing for the configuration.")
      end
      if not [:none,:yum].include?(subscription_type)
        # The other subscription types require username and password
        self.class.subscription_info(subscription_type)[:attrs].each_key do |attr|
          next if not [:rh_username,:rh_password].include?(attr)
          if self.send(attr).nil?
            return false if check == :basic
            errors << Installer::SubscriptionSettingMissingException.new("The #{attr.to_s} value is missing, but it is required for supscription type #{subscription_type.to_s}.")
          end
        end
      end
      self.class.object_attrs.each do |attr|
        if check == :basic
          return false if not self.class.valid_attr?(attr, self.send(attr), check)
        else
          errors.concat(self.class.valid_attr?(attr, self.send(attr), check))
        end
      end
      return true if check == :basic
      errors
    end

    def to_hash
      export_hash = {}
      self.class.object_attrs.each do |attr|
        value = self.send(attr)
        if not value.nil?
          key = attr.to_s
          if attr == :subscription_type
            key = 'type'
            value = value.to_s
          end
          export_hash[key] = value
        end
      end
      export_hash
    end
  end
end
