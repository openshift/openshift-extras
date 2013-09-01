require 'i18n'
require 'pathname'
require 'yaml'

module Installer
  module Helpers
    include I18n

    def file_check(filepath)
      # Test for the presence of the config file
      pn = Pathname.new(filepath)
      pn.exist?() and pn.readable?()
    end

    def gem_root_dir
      @gem_root_dir ||= File.expand_path '../../../', __FILE__
    end

    # SOURCE for #which:
    # http://stackoverflow.com/questions/2108727/which-in-ruby-checking-if-program-exists-in-path-from-ruby
    def which(cmd)
      exts = ENV['PATHEXT'] ? ENV['PATHEXT'].split(';') : ['']
      ENV['PATH'].split(File::PATH_SEPARATOR).each do |path|
        exts.each { |ext|
          exe = File.join(path, "#{cmd}#{ext}")
          return exe if File.executable? exe
        }
      end
      return nil
    end

    def i18n_configured?
      @i18n_configured ||= false
    end

    def translate text
      unless i18n_configured?
        I18n.load_path += Dir[gem_root_dir + '/config/locales/*.yml']
        @i18n_configured = true
      end
      I18n.t text
    end
  end
end

