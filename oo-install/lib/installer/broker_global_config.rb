require 'installer/helpers'

module Installer
  class BrokerGlobalConfig
    include Installer::Helpers

    attr_accessor :user_default_gear_sizes, :default_gear_size, :valid_gear_sizes, :broker_hostname

    def initialize broker_global_config
      @valid_gear_sizes = broker_global_config['valid_gear_sizes'].split(',').map{ |s| s.strip }.uniq
      @user_default_gear_sizes = broker_global_config['user_default_gear_sizes'].split(',').map{ |s| s.strip }.uniq
      @default_gear_size = broker_global_config['default_gear_size']
      @broker_hostname = broker_global_config['broker_hostname']
    end

    def add_valid_gear_size(size)
      @valid_gear_sizes = valid_gear_sizes.concat([size]).uniq
    end

    def add_user_default_gear_size(size)
      @valid_gear_sizes = valid_gear_sizes.concat([size]).uniq
      @user_default_gear_sizes = user_default_gear_sizes.concat([size]).uniq
    end

    def remove_user_default_gear_size(size)
      @user_default_gear_sizes.delete_if{ |s| s == size }
    end

    def remove_valid_gear_size(size)
      @valid_gear_sizes.delete_if{ |s| s == size }
      @user_default_gear_sizes.delete_if{ |s| s == size }
    end

    def is_valid?(check=:basic)
      errors = []
      if valid_gear_sizes.length == 0
        return false if check == :basic
        errors << Installer::BrokerGlobalSettingsException.new("At least one valid gear size must be configured.")
      end
      if user_default_gear_sizes.length == 0
        return false if check == :basic
        errors << Installer::BrokerGlobalSettingsException.new("At least one user default gear size must be configured.")
      end
      if not is_valid_string?(default_gear_size) or not user_default_gear_sizes.include?(default_gear_size)
        return false if check == :basic
        errors << Installer::BrokerGlobalSettingsException.new("A default gear size must be selected from the available user default gear sizes.")
      end
      # Make sure all user default gears exist in the valid gears list
      bogus_sizes = user_default_gear_sizes.select{ |s| not valid_gear_sizes.include?(s) }
      if bogus_sizes.length > 0
        return false if check == :basic
        errors << Installer::BrokerGlobalSettingsException.new("One or more user default gear sizes is not included in the valid gear sizes")
      end
      return true if check == :basic
      errors
    end

    def to_hash
      {
        'valid_gear_sizes'        => valid_gear_sizes.join(','),
        'user_default_gear_sizes' => user_default_gear_sizes.join(','),
        'default_gear_size'       => default_gear_size,
        'broker_hostname'         => broker_hostname,
      }
    end
  end
end
