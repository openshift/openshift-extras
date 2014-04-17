module MetricsPluginTemplate
  module ClassMethods
    def repository
      @repository ||= []
    end

    def inherited(klass)
      repository << klass
    end
  end

  def self.included(klass)
    klass.extend ClassMethods
  end
end

class MetricsPlugin
  include MetricsPluginTemplate

  def initialize(handler)
    @handler = handler
  end

  def configure
  end

  def config
    @handler.config
  end

  def process(app, gear, timestamp, fields)
  end

  def name
    @name ||= self.class.name.gsub(/Plugin$/, '').downcase
  end

  def disabled?
    config[name] and config[name]['enabled'] == false
  end

  def enabled?
    not disabled?
  end

  def metadata_s(line_metadata)
    @handler.metadata.map do |field_or_hash|
      field = field_or_hash
      field = field_or_hash.keys[0] if field_or_hash.is_a?(Hash)

      line_metadata[field]
    end.compact.join('.')
  end

  def logger
    handler.logger
  end
end
