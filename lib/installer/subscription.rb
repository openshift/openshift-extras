require 'installer/helpers'

module Installer
  class Subscription
    include Installer::Helpers

    @object_attrs = [:subscription_type, :repos_base, :rhel_repo, :jboss_repo_base, :rhel_optional_repo, :sm_reg_name, :sm_reg_pass, :sm_reg_pool, :rhn_reg_name, :rhn_reg_pass, :rhn_reg_actkey]

    attr_reader :config, :type
    attr_accessor @object_attrs


    def self.subscription_types
      { :yum => {
          :desc => 'Get packages from yum and do not use a subscription',
          :attrs => [:repos_base, :rhel_repo, :jboss_repo_base, :rhel_optional_repo],
        },
        :rhsm => {
          :desc => 'Use Red Hat Subscription Manager',
          :attrs => [:sm_reg_name, :sm_reg_pass, :sm_reg_pool],
        },
        :rhn => {
          :desc => 'Use Red Hat Network',
          :attrs => [:rhn_reg_name, :rhn_reg_pass, :rhn_reg_actkey],
        },
      }
    end

    def initialize config, subscription
      @config = config
      @object_attrs.each do |attr|
        attr_str = attr.to_s
        if subscription.has_key?(attr_str)
          self.send("#{attr_str}=".to_sym, subscription(attr_str))
        end
      end
    end

    def is_valid?(check=:basic)
      @object_attrs.each do |attr|
        value = self.send(attr)
        # Test for valid subscription type
        if attr == :subscription_type and not self.class.subscription_types.has_key?(value.to_sym)
          return false if check == :basic
          raise Installer::SubscriptionTypeNotRecognizedException.new("Subscription type '#{value}' is not recognized.")
        elsif not attr == :subscription_type
          # Test for valid settings by subscription type
          if not self.class.subscription_types[subscription_type][:attrs].include?(attr)
            return false if check == :basic
            raise Installer::InvalidSubscriptionSettingException.new("Subscription setting '#{attr.to_s}' is not valid for subscription type '#{subscription_type}'.")
          elsif value.nil?
            # Make sure relevant values aren't nil. we'll do more value checking next
            return false if check == :basic
            raise Installer::SubscriptionSettingMissingException.new("Subscription setting '#{attr.to_s}' is required for subscription type '#{subscription_type}'.")
          end
          # Test for valid values by setting type
          if ([:repos_base, :rhel_repo, :jboss_repo_base, :rhel_optional_repo].include?(attr) and not is_valid_url?(value)) or
             ([:sm_reg_name,:rhn_reg_name].include?(attr) and not is_valid_username?(value)) or
             ([:sm_reg_pass, :sm_reg_pool, :rhn_reg_pass, :rhn_reg_actkey].include?(attr) and not is_valid_string?(value))
            return false if check == :basic
            raise Installer::SubscriptionSettingNotValidException.new("Subscription setting '#{attr.to_s}' has invalid value '#{value}'.")
          end
        end
      end

    end

    def to_hash
      export_hash = {}
      @object_attrs.each do |attr|
        value = self.send(attr)
        if not value.nil?
          export_hash[attr.to_s] = value
        end
      end
      export_hash
    end
  end
end
