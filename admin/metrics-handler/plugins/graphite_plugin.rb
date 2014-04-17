require 'socket'

class GraphiteClient
  def initialize(host, port)
    @host = host
    @port = port
  end

  def carbon
    begin
      @carbon ||= TCPSocket.new(host, port)
    rescue => e
      @carbon = nil
    end

    @carbon
  end

  def send(data)
    begin
      carbon.puts(data) if carbon
    rescue => e
      @carbon = nil
    end
  end
end

class GraphitePlugin < MetricsPlugin
  def configure
    @client = GraphiteClient.new(config['graphite']['host'], config['graphite']['port'].to_i)
  end

  def process(timestamp, metadata, metrics)
    fields.each do |key, value|
      @client.send "#{metadata_s(metadata)} #{value} #{timestamp.to_i}"
    end
  end
end
