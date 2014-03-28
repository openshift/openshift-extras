require 'minitest/spec'
require 'minitest/autorun'

require 'metrics_handler'

describe MetricsHandler do
  before do
    test_config = File.join(File.dirname(__FILE__), 'test_config.yml')
    @mh = MetricsHandler.new(%W(-c #{test_config}))
  end

  it "parses command line options" do
    File.basename(@mh.config_file).must_equal 'test_config.yml'
  end

  it "has a default configuration" do
    @mh = MetricsHandler.new
    @mh.config.must_equal @mh.default_config
  end

  it "loads plugins" do
    @mh.plugins.count.must_equal 3
    %w(file stdout graphite).each { |p| @mh.plugins.map(&:name).must_include(p) }
  end

  it "logs to stdout by default" do
    @mh.logger.must_be_instance_of(Logger)
  end

  it "merges a config file with defaults" do
    expected_config = @mh.default_config.dup
    expected_config['metadata'][-1] = {'cart' => {'required' => false}}
    expected_config['graphite'] = {
      'enabled' => false,
      'host' => 'localhost',
      'port' => 2003
    }

    expected_config['file'] = {
      'enabled' => false,
      'path' => '/tmp/metrics.log'
    }

    @mh.config.must_equal expected_config
  end

  describe '#metadata' do
    it "delegates to @config['metadata']" do
      @mh.config['metadata'] = 'abc'
      @mh.metadata.must_equal 'abc'
    end
  end

  describe "#metadata_info" do
    describe "with a String" do
      it "returns the field name and required=true" do
        @mh.metadata_info('app').must_equal ['app', true]
      end
    end

    describe "with a Hash" do
      [true, false].each do |v|
        describe "with required=#{v}" do
          it "returns the field name and required=#{v}" do
            @mh.metadata_info({'cart' => {'required' => v}}).must_equal ['cart', v]
          end
        end
      end
    end
  end

  describe "#extract_line_metadata" do
    it "handles an empty string" do
      @mh.extract_line_metadata('').must_equal({})
    end

    it "handles no metadata" do
      @mh.extract_line_metadata('a=b some text').must_equal({})
    end

    it "handles metadata" do
      extracted = @mh.extract_line_metadata('a=b app=myapp c=d some text here cart=mycart')
      extracted.must_equal({'app' => 'myapp', 'cart' => 'mycart'})
    end
  end

  describe "#extract_metrics" do
    describe "with no metrics" do
      it "returns an empty Hash" do
        line = "type=metric some text"
        extracted = @mh.extract_metrics(line, 0)
        extracted.must_equal({})
      end
    end

    describe "with a metric missing the key" do
      it "returns an empty Hash" do
        line = "type=metric =123"
        extracted = @mh.extract_metrics(line, 0)
        extracted.must_equal({})
      end
    end

    describe "with valid metrics" do
      it "returns the metrics in a Hash" do
        line = "blah blah type=metric abc=123 some more text def=456 foo bar"
        index = line.index('type=metric')
        extracted = @mh.extract_metrics(line, index)
        extracted.must_equal('abc'=>'123', 'def'=>'456')
      end
    end
  end

  describe "#have_all_required_metadata?" do
    describe 'with all required metadata' do
      it "returns true" do
        line = "type=metric app=app1 gear=gear1 cart=cart1 k1=v1"
        metadata = @mh.extract_line_metadata(line)
        @mh.have_all_required_metadata?(metadata).must_equal true
      end
    end

    describe 'without all required metadata' do
      it "returns false" do
        line = "type=metric app=app1 k1=v1"
        metadata = @mh.extract_line_metadata(line)
        @mh.have_all_required_metadata?(metadata).must_equal false
      end
    end
  end

  describe "#run" do
    describe "without type=metric" do
      it "is a no-op" do
        i = 0
        gets_input = -> do
          if i == 0
            i += 1
            return 'some text'
          end

          nil
        end

        failed = false

        @mh.stub :gets, gets_input do
          @mh.stub :extract_timestamp, ->(l) { failed=true} do
            @mh.run
          end
        end

        failed.must_equal false
      end
    end

    describe "with type=metric" do
      describe "without timestamp" do
        it "is a no-op" do
          i = 0
          gets_input = -> do
            if i == 0
              i += 1
              return 'type=metric some text'
            end

            nil
          end

          failed = false

          @mh.stub :gets, gets_input do
            @mh.stub :extract_timestamp, nil do
              @mh.stub :extract_line_metadata, ->(l) { failed=true} do
                @mh.run
              end
            end
          end

          failed.must_equal false
        end
      end

      describe "with timestamp" do
        describe "when missing required metadata" do
          it "is a no-op" do
            i = 0
            gets_input = -> do
              if i == 0
                i += 1
                return '2014-02-27T14:50:22.011665-05:00 type=metric app=app1 a=1'
              end

              nil
            end

            failed = false

            @mh.stub :gets, gets_input do
              @mh.stub :extract_metrics, ->(l,i) { failed = true } do
                @mh.run
              end
            end

            failed.must_equal false
          end
        end

        describe "with required metadata" do
          it "plugins are invoked" do
            i = 0
            gets_input = -> do
              if i == 0
                i += 1
                return '2014-02-27T14:50:22.011665-05:00 type=metric app=app1 gear=gear1 cart=cart1 a=1 b=2'
              end

              nil
            end

            output = []
            puts_capture = ->(line) do
              output << line
            end

            @mh.stub :gets, gets_input do
              @mh.plugins.last.stub :puts, puts_capture do
                @mh.run
              end
            end

            output.size.must_equal 2
            output[0].must_equal 'app1.gear1.cart1.a 1 1393530622'
            output[1].must_equal 'app1.gear1.cart1.b 2 1393530622'
          end
        end
      end
    end
  end
end
