class StdoutPlugin < MetricsPlugin
  def process(timestamp, metadata, metrics)
    metrics.each do |key, value|
      puts "#{metadata_s(metadata)}.#{key} #{value} #{timestamp.to_i}"
    end
  end
end
