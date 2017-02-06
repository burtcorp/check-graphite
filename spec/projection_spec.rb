require 'check_graphite/projection'
require 'nagios_check'

describe 'CheckGraphite::Projection.to_s_signif_digits' do
  it 'nan is expressed as "undefined"' do
    expect(CheckGraphite::Projection.to_s_signif_digits(Float::NAN)).to eq('undefined')
  end
  it 'formats small floats with 3 significant digits' do
    expect(CheckGraphite::Projection.to_s_signif_digits(1.2345677)).to eq('1.23')
  end
  it 'formats small floats with 3 significant digits, rounding 0.5 up' do
    expect(CheckGraphite::Projection.to_s_signif_digits(1.235)).to eq('1.24')
  end
  it 'formats large floats with 3 significant digits' do
    expect(CheckGraphite::Projection.to_s_signif_digits(1334999.0)).to eq('1330000.0')
  end
  it 'formats 1.0 as 1.0 to show it is a float despite trailing zero not being significant' do
    expect(CheckGraphite::Projection.to_s_signif_digits(1.0)).to eq('1.0')
  end
  it 'formats really small float as decimal, defeating rubys urge to print anything smaller than 1e-4 in engineering notation' do
    expect(CheckGraphite::Projection.to_s_signif_digits(0.000002345678)).to eq('0.00000235')
  end
end

describe CheckGraphite::Projection do
  let :check do
    Class.new do
      attr_reader :values
      include NagiosCheck
      include CheckGraphite::Projection
    end.new
  end

  describe 'when parsing a pearson threshold option' do
    subject do |example|
      check.prepare
      check.send(:parse_options, example.metadata[:description_args][0])
      check.options.p_threshold
    end

    it ['--p-threshold', '0.75'] { should eq(0.75) }
    it ['--p-threshold', '2'] { expect { subject }.to raise_error(/0 <=.*2.*<= 1/) }
    it ['--p-threshold', 'foo'] { expect { subject }.to raise_error(/float/) }

    describe 'when passing --p-threshold without' do
      it 'should fail with error saying you need to give --projection' do
        expect {
          check.prepare
          check.send(:parse_options, ['--p-threshold', '0.75'])
          check.projected_value([[10,0], [9,1], [8,2]])
        }.to raise_error(/--projection/)
      end
    end
  end

  describe 'when looking at the primary value' do
    let(:projection) { '2sec' }
    let(:options) { ['--projection', projection] }

    subject do
      check.prepare
      check.send(:parse_options, options)
      check.options.processor.call(datapoints)
      check.values.first[1]
    end

    context 'given a linearly decreasing series and a projection of 2 sec' do
      let(:datapoints) { [[10,0], [9,1], [8,2]] }

      it 'linerarly extrapolates value to be 6' do
        should be_within(0.01).of(6)
      end
    end

    context 'given a constant series and a projection of 2 sec' do
      let(:datapoints) { [[10,0], [10,1], [10,2]] }

      it 'linearly extrapolates the value to remain 01' do
        should be_within(0.01).of(10)
      end
    end

    context 'given a constant series with a p-value below threshold' do
      let(:datapoints) { [[10,0], [10,1], [10,2]] }
      let(:options) { ['--projection', projection, '--p-threshold', '0.3'] }

      it 'returns a projection even tho p-value is NaN' do
        should be_within(0.01).of(10)
      end
    end

    context 'given a series with a p-value below threshold' do
      let(:datapoints) { [[5,0], [1,1], [10,2]] }
      let(:options) { ['--projection', projection, '--p-threshold', '0.9'] }

      it 'returns nil because nagios_check will turn it into UNKNOWN' do
        should be(nil)
      end
    end
  end

  describe 'when looking at the p-value' do
    let(:projection) { '2sec' }
    subject do
      check.prepare
      check.send(:parse_options, ['--projection', projection])
      check.options.processor.call(datapoints)
      check.values['p-value']
    end

    context 'given a constant series (where Pearson is undefined)' do
      let(:datapoints) { [[10,0], [10,1], [10,2]] }
      it { should eq('undefined') }
    end

    context 'given a linearly decreasing series' do
      let(:datapoints) { [[10,0], [9,1], [8,2]] }

      it { should eq("1.0") }
    end
  end
end

describe 'when invoking graphite with --projection' do
  before do
    FakeWeb.register_uri(
      :get, "http://your.graphite.host/render?target=collectd.somebox.load.load.midterm&from=-30seconds&format=json",
      :body => '[{"target": "collectd.somebox.load.load.midterm", "datapoints": [[1.0, 1339512060], [2.0, 1339512120], [6.0, 1339512180], [7.0, 1339512240]]}]',
      :content_type => "application/json"
    )
    stub_const("ARGV", %w{
      -H http://your.graphite.host/render
      -M collectd.somebox.load.load.midterm
      -c 0:10
      --name ze-name
    } + options)
  end

  context 'given no --p-threshold' do
    let(:options) { ['--projection', '5min'] }

    it 'outputs value formatted to 3 significant digits, projection interval and p-value' do
      c = CheckGraphite::Command.new
      STDOUT.should_receive(:puts).with(match(/ze-name=18.8 in 5min.*p-value=0.9/))
      lambda { c.run }.should raise_error SystemExit
    end
  end

  context 'given a low p-threshold' do
    let(:options) { ['--projection', '5min', '--p-threshold', '0.3'] }

    it 'outputs value formatted to 3 significant digits, projection interval and p-value' do
      c = CheckGraphite::Command.new
      STDOUT.should_receive(:puts).with(match(/ze-name=18.8 in 5min.*p-value=0.9/))
      lambda { c.run }.should raise_error SystemExit
    end
  end

  context 'given a high p-threshold' do
    let(:options) { ['--projection', '5min', '--p-threshold', '0.99'] }

    it 'gives unknown status and says p-value is too low' do
      c = CheckGraphite::Command.new
      STDOUT.should_receive(:puts).with(match(/UNKNOWN: No projection on ze-name.*.*0.981 < 0.99/))
      lambda { c.run }.should raise_error SystemExit
    end
  end
end
