class FilePlugin < MetricsPlugin
  def configure
    @file = config['file']['path']
  end

  def process(timestamp, metadata, metrics)
    File.open(@file, 'a') do |f|
      metrics.each do |key, value|
        f.puts "#{metadata_s(metadata)}.#{key} #{value} #{timestamp.to_i}"
      end
    end
  end
end
