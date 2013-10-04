require 'installer/helpers'

module Installer
  class Subscription
    include Installer::Helpers

    @object_attrs = [:subscription_type, :rh_username, :rh_password, :repos_base, :rhel_repo, :jboss_repo_base, :rhel_optional_repo, :sm_reg_pool, :sm_reg_pool_rhel, :rhn_reg_actkey]

    attr_reader :config, :type
    attr_accessor *@object_attrs

    class << self
      def subscription_types
        { :none => {
            :desc => 'No subscription necessary',
            :attrs => {},
            :attr_order => [],
          },
          :yum => {
            :desc => 'Get packages from yum and do not use a subscription',
            :attrs => {
              :repos_base => 'The base URL for the OpenShift repositories',
              :rhel_repo => 'The URL for a RHEL 6 yum repository',
              :jboss_repo_base => 'The base URL for the JBoss repositories',
              :rhel_optional_repo => 'The URL for a RHEL 6 Optional repository',
            },
            :attr_order => [:repos_base,:rhel_repo,:jboss_repo_base,:rhel_optional_repo],
          },
          :rhsm => {
            :desc => 'Use Red Hat Subscription Manager',
            :attrs => {
              :rh_username => 'Red Hat Login username',
              :rh_password => 'Red Hat Login password',
              :sm_reg_pool => 'Pool ID for OpenShift subscription',
            },
            :attr_order => [:rh_username,:rh_password,:sm_reg_pool],
          },
          :rhn => {
            :desc => 'Use Red Hat Network',
            :attrs => {
              :rh_username => 'Red Hat Login username',
              :rh_password => 'Red Hat Login password',
              :rhn_reg_actkey => 'RHN account activation key',
            },
            :attr_order => [:rh_username,:rh_password,:rhn_reg_actkey],
          },
        }
      end

      def object_attrs
        @object_attrs
      end

      def valid_attr? attr, value, check=:basic
        if attr == :subscription_type and not self.class.subscription_types.has_key?(value.to_sym)
          return false if check == :basic
          raise Installer::SubscriptionTypeNotRecognizedException.new("Subscription type '#{value}' is not recognized.")
        elsif not attr == :subscription_type and not value.nil?
          # We have to be pretty flexible here, so we basically just format-check the non-nil values.
          if ([:repos_base, :rhel_repo, :jboss_repo_base, :rhel_optional_repo].include?(attr) and not is_valid_url?(value)) or
             (attr == :rh_username and not is_valid_email_addr?(value)) or
             ([:rh_password, :sm_reg_pool, :sm_reg_pool_rhel, :rhn_reg_actkey].include?(attr) and not is_valid_string?(value))
            return false if check == :basic
            raise Installer::SubscriptionSettingNotValidException.new("Subscription setting '#{attr.to_s}' has invalid value '#{value}'.")
          end
        end
        true
      end
    end

    def initialize config, subscription={}
      @config = config
      self.class.object_attrs.each do |attr|
        attr_str = attr.to_s
        if subscription.has_key?(attr_str)
          self.send("#{attr_str}=".to_sym, subscription[attr_str])
        end
      end
    end

    def is_complete?
      return false if subscription_type.nil?
      if ['none','yum'].include?(subscription_type)
        # These methods do not require other settings
        return true
      else
        # These others require -all- related attrs
        self.class.subscription_types[subscription_type.to_sym][:attrs].each_key do |attr|
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

    def to_hash
      export_hash = {}
      self.class.object_attrs.each do |attr|
        value = self.send(attr)
        if not value.nil?
          export_hash[attr.to_s] = value
        end
      end
      export_hash
    end
  end
end
