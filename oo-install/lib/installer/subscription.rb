require 'installer/helpers'

module Installer
  class Subscription
    include Installer::Helpers

    @object_attrs = [:subscription_type, :rh_username, :rh_password, :repos_base, :os_repo, :jboss_repo_base, :os_optional_repo, :sm_reg_pool, :sm_reg_pool_rhel, :rhn_reg_actkey]

    attr_reader :config, :type
    attr_accessor *@object_attrs

    class << self
      def subscription_types(context)
        type_map = {}
        valid_types_for_context(context).each do |type|
          type_map[type] = subscription_info_for_type(type)
        end
        type_map
      end

      def object_attrs
        @object_attrs
      end

      def valid_attr? attr, value, check=:basic
        if attr == :subscription_type
          begin
            subscription_info_for_type(value.to_sym)
          rescue Installer::SubscriptionTypeNotRecognizedException => e
            if check == :basic
              return false
            else
              raise
            end
          end
        elsif not attr == :subscription_type and not value.nil?
          # We have to be pretty flexible here, so we basically just format-check the non-nil values.
          if ([:repos_base, :os_repo, :jboss_repo_base, :os_optional_repo].include?(attr) and not is_valid_url?(value)) or
             (attr == :rh_username and not is_valid_email_addr?(value)) or
             ([:rh_password, :sm_reg_pool, :sm_reg_pool_rhel, :rhn_reg_actkey].include?(attr) and not is_valid_string?(value))
            return false if check == :basic
            raise Installer::SubscriptionSettingNotValidException.new("Subscription setting '#{attr.to_s}' has invalid value '#{value}'.")
          end
        end
        true
      end

      def subscription_info_for_type(subscription_type)
        case subscription_type
        when :none
          return {
            :desc => 'No subscription necessary',
            :attrs => {},
            :attr_order => [],
          }
        when :yum
          return {
            :desc => 'Get packages from yum and do not use a subscription',
            :attrs => {
              :repos_base => 'The base URL for the OpenShift repositories',
              :os_repo => 'The URL of a yum repository for the operating system',
              :jboss_repo_base => 'The base URL for the JBoss repositories',
              :os_optional_repo => 'The URL for an "Optional" repository for the operating system',
            },
            :attr_order => [:repos_base,:os_repo,:jboss_repo_base,:os_optional_repo],
          }
        when :rhsm
          return {
            :desc => 'Use Red Hat Subscription Manager',
            :attrs => {
              :rh_username => 'Red Hat Login username',
              :rh_password => 'Red Hat Login password',
              :sm_reg_pool => 'Pool ID for OpenShift subscription',
              :sm_reg_pool_rhel => 'Pool ID for RHEL subscription',
            },
            :attr_order => [:rh_username,:rh_password,:sm_reg_pool],
          }
        when :rhn
          return {
            :desc => 'Use Red Hat Network',
            :attrs => {
              :rh_username => 'Red Hat Login username',
              :rh_password => 'Red Hat Login password',
              :rhn_reg_actkey => 'RHN account activation key',
            },
            :attr_order => [:rh_username,:rh_password,:rhn_reg_actkey],
          }
        else
          raise Installer::SubscriptionTypeNotRecognizedException.new("Subscription type '#{subscription_type}' is not recognized.")
        end
      end

      def valid_types_for_context(context)
        case context
        when :origin, :origin_vm
          return [:none,:yum]
        when :ose
          return [:none,:yum,:rhsm,:rhn]
        else
          raise Installer::UnrecognizedContextException.new("Installer context '#{context}' is not supported.")
        end
      end
    end

    def initialize config, subscription={}
      @config = config
      self.class.object_attrs.each do |attr|
        attr_str = attr == :subscription_type ? 'type' : attr.to_s
        if subscription.has_key?(attr_str)
          self.send("#{attr.to_s}=".to_sym, subscription[attr_str])
        end
      end
    end

    def is_complete?
      return false if subscription_type.nil?
      if ['none','yum'].include?(subscription_type)
        # These methods do not require other settings
        return true
      else
        # These others require username and password
        self.class.subscription_info_for_type(subscription_type.to_sym)[:attrs].each_key do |attr|
          next if not [:rh_username,:rh_password].include?(attr)
          return false if self.send(attr).nil?
        end
      end
      true
    end

    def is_valid?(check=:basic)
      self.class.object_attrs.each do |attr|
        return false if not self.class.valid_attr?(attr, self.send(attr), check)
      end
    end

    def test_commands
      return self.class.subscription_types[subscription_type][:test_commands]
    end

    def to_hash
      export_hash = {}
      self.class.object_attrs.each do |attr|
        value = self.send(attr)
        if not value.nil?
          key = attr == :subscription_type ? 'type' : attr.to_s
          export_hash[key] = value
        end
      end
      export_hash
    end
  end
end
