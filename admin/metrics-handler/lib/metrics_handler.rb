require 'time'
require 'yaml'
require 'optparse'
require 'logger'

require_relative '../plugins/metrics_plugin'

DEFAULT_CONFIG_FILE = '/etc/openshift/metrics_handler.yml'

class MetricsHandler
  attr_reader :config, :config_file, :plugins, :logger

  def initialize(argv=ARGV)
    @config_file = DEFAULT_CONFIG_FILE

    parse_options(argv)
    load_config
    setup_logging
    require_plugins
    instantiate_plugins
    configure_plugins
  end

  def default_config
    {
      'metadata' => %w(app gear cart),
      'logger' => 'console'
    }
  end

  def load_config
    @config = default_config
    if File.exist?(@config_file)
      loaded_config = YAML.load_file(@config_file)
      @config.merge!(loaded_config)
    end
  end

  def setup_logging
    if @config['logger'] == 'console'
      @logger = Logger.new(STDOUT)
    elsif @config['logger'] == 'syslog'
      require 'syslog-logger'
      @logger = Logger::Syslog.new('openshift-metrics')
    else
      raise "Invalid logger '#{@config['logger']}' specified. Valid options are 'console' and 'syslog'."
    end
    @logger.level = Logger::DEBUG
  end

  def parse_options(argv)
    OptionParser.new do |opts|
      opts.on('-c', '--config FILE', 'Config file locaiton') do |file|
        @config_file = file
      end
    end.parse!(argv)
  end

  def require_plugins
    @plugin_dir = File.join(File.dirname(__FILE__), '..', 'plugins')

    @plugin_files = Dir.glob(File.join(@plugin_dir, '*'))
                      .find_all { |f| File.file?(f) }
                      .reject { |f| f == 'metrics_plugin.rb' }

    @plugin_files.each do |p|
      begin
        @logger.info "Attempting to load #{p}"
        require p
      rescue LoadError => e
        @logger.info "Error loading #{p}"
      end
    end
  end

  def instantiate_plugins
    @plugins = MetricsPlugin.repository.collect do |plugin|
      begin
        plugin.new(self)
      rescue => e
        @logger.warn "Error loading plugin #{plugin}: #{e.message}"
        nil
      end
    end.to_a.compact

    @logger.error "No valid plugins found in #{@plugin_dir}" if @plugins.empty?

    @logger.info "Loaded plugins: #{@plugins.map(&:name).join(', ')}"
    @logger.info "Enabled plugins: #{@plugins.map {|p| p.name if p.enabled?}.compact.join(',')}"
  end

  def configure_plugins
    @plugins.each do |p|
      begin
        p.configure if p.enabled?
      rescue => e
        @logger.warn "Error configuring plugin #{p}: #{e.message}"
      end
    end
  end

  def metadata
    @config['metadata']
  end

  def metadata_info(md)
    case md
    when String
      [md, true]
    when Hash
      field = md.keys[0]
      [field, md[field]['required']]
    end
  end

  def extract_line_metadata(line)
    {}.tap do |line_metadata|
      metadata.each do |md|
        field, _ = metadata_info(md)

        if line =~ /#{field}=([^ ]+)/
          line_metadata[field] = $1 if line =~ /#{field}=([^ ]+)/
          @logger.debug "#{field}=#{$1}"
        end
      end
    end
  end

  def extract_metrics(line, index)
    # get all the k=v pairs (including type=metric)
    kv_pairs = line[index..-1].split(' ')

    # remove the first pair (type=metric)
    kv_pairs.shift

    # remove anything that doesn't have an =
    kv_pairs.delete_if { |e| i = e.index('='); i.nil? or i < 1 }

    # convert the k=v pairs into a hash
    metrics = Hash[kv_pairs.map { |kv| kv.split('=') }]
  end

  def have_all_required_metadata?(line_metadata)
    metadata.all? do |md|
      field, required = metadata_info(md)
      
      not required or line_metadata.has_key?(field)
    end
  end

  def extract_timestamp(line)
    # 2014-02-27T14:50:22.011665-05:00
    timestamp = Time.parse($1) if line =~ /^([^ ]+) /
  end

  def run
    while line = gets
      begin
        line = line.chomp

        @logger.debug("Received line: #{line}")

        index = line.index('type=metric')
        # make sure we have index
        next unless index and index >= 0

        # make sure we have timestamp
        timestamp = extract_timestamp(line)
        next if timestamp.nil?

        @logger.debug "Timestamp = #{timestamp}"

        line_metadata = extract_line_metadata(line)

        # skip if we don't have what we need
        next unless have_all_required_metadata?(line_metadata)

        metrics = extract_metrics(line, index)

        # remove things like app=x, gear=y, etc
        metadata.each do |md|
          field, _ = metadata_info(md)
          metrics.delete(field)
        end

        @plugins.each do |plugin|
          if plugin.enabled?
            @logger.debug "Invoking plugin '#{plugin.name}'"

            plugin.process(timestamp, line_metadata, metrics)

            @logger.debug "DONE Invoking plugin '#{plugin.name}'"
          else
            @logger.debug "Plugin '#{plugin.name}' is disabled - skipping"
          end
        end
      end
    end
  end
end
