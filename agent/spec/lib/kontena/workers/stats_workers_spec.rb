require_relative '../../../spec_helper'
require_relative '../../helpers/fixtures_helpers'

describe Kontena::Workers::StatsWorker do
  include FixturesHelpers

  let(:queue) { Queue.new }
  let(:subject) { described_class.new(queue, false) }

  let(:container) { spy(:container, id: 'foo', labels: {}) }

  before(:each) { Celluloid.boot }
  after(:each) { Celluloid.shutdown }

  describe '#initialize' do
    it 'subscribes to agent:node_info channel' do
      expect(subject.wrapped_object).to receive(:on_node_info)
      Celluloid::Notifications.publish('agent:node_info')
      sleep 0.01
    end
  end

  describe '#collect_stats' do
    it 'loops through all containers' do
      expect(subject.wrapped_object).to receive(:get).once.with('/api/v1.2/subcontainers').and_return([
        { namespace: 'docker', id: 'id', name: '/docker/id' },
      ])
      expect(subject.wrapped_object).to receive(:send_container_stats).once { |args| expect(args[:id]).to eq 'id' }
      subject.collect_stats
    end

    it 'ignores systemd mount cgroups' do
      expect(subject.wrapped_object).to receive(:get).once.with('/api/v1.2/subcontainers').and_return([
        { namespace: 'docker', id: 'id1', name: '/docker/id' },
        { namespace: 'docker', id: 'id2', name: '/system.slice/var-lib-docker-containers-id-shm.mount' },
      ])
      expect(subject.wrapped_object).to receive(:send_container_stats).once { |args| expect(args[:id]).to eq 'id1' }
      subject.collect_stats
    end

    it 'does nothing on get error' do
      expect(subject.wrapped_object).to receive(:get).once.with('/api/v1.2/subcontainers').and_return(nil)
      expect(subject.wrapped_object).not_to receive(:send_container_stats)
      subject.collect_stats
    end

    it 'does not call send_stats if no container stats found' do
      expect(subject.wrapped_object).to receive(:get).once.with('/api/v1.2/subcontainers').and_return({})
      expect(subject.wrapped_object).not_to receive(:send_container_stats)
      subject.collect_stats
    end
  end

  describe '#get' do
    it 'gets cadvisor stats for given container' do
      excon = double
      response = double
      allow(subject.wrapped_object).to receive(:client).and_return(excon)
      expect(excon).to receive(:get).with(:path => '/api/v1.2/foo').and_return(response)
      allow(response).to receive(:status).and_return(200)
      allow(response).to receive(:body).and_return('{"foo":"bar"}')
      expect(subject.get('/api/v1.2/foo')).to eq({:foo => "bar"})
    end

    it 'retries 3 times' do
      excon = double
      allow(subject.wrapped_object).to receive(:client).and_return(excon)
      allow(excon).to receive(:get).with(:path => '/api/v1.2/foo').and_raise(Excon::Errors::Error)
      expect(excon).to receive(:get).exactly(3).times
      subject.get('/api/v1.2/foo')
    end


    it 'return nil on 500 status' do
      excon = double
      response = double
      allow(subject.wrapped_object).to receive(:client).and_return(excon)
      allow(excon).to receive(:get).with(:path => '/api/v1.2/foo').and_return(response)
      allow(response).to receive(:status).and_return(500)
      allow(response).to receive(:body).and_return('{"foo":"bar"}')
      expect(subject.get('/api/v1.2/foo')).to eq(nil)
    end

  end

  describe '#on_node_info' do
    it 'initializes statsd client if node has statsd config' do
      info = {
        'grid' => {
          'stats' => {
            'statsd' => {
              'server' => '192.168.24.33',
              'port' => 8125
            }
          }
        }
      }
      expect(subject.statsd).to be_nil
      subject.on_node_info('agent:node_info', info)
      expect(subject.statsd).not_to be_nil
    end

    it 'does not initialize statsd if no statsd config exists' do
      info = {
        'grid' => {
          'stats' => {}
        }
      }
      expect(subject.statsd).to be_nil
      subject.on_node_info('agent:node_info', info)
      expect(subject.statsd).to be_nil
    end
  end

  describe '#send_statsd_metrics' do
    let(:event) do
      {
        id: 'aaaaaa',
        spec: {
          labels: {
            :'io.kontena.service.name' => 'foobar'
          }
        },
        cpu: {
          usage_pct: 12.32
        },
        memory: {
          usage: 24 * 1024 * 1024
        },
        filesystem: [],
        diskio: [],
        network: []
      }
    end

    let(:statsd) do
      spy(:statsd)
    end

    it 'sends statsd metrics' do
      allow(subject.wrapped_object).to receive(:statsd).and_return(statsd)
      expect(statsd).to receive(:gauge)
      subject.send_statsd_metrics('foobar', event)
    end
  end

describe '#send_container_stats' do
    let(:event) do
      JSON.parse(fixture('container_stats.json'), symbolize_names: true)
    end

    it 'sends container stats' do
      expect(subject.wrapped_object).to receive(:send_statsd_metrics).with('weave', hash_including({
          id: 'a675a5cd5f36ba747c9495f3dbe0de1d5f388a2ecd2aaf5feb00794e22de6c5e',
          spec: 'spec',
          cpu: {
            usage: 100000000,
            usage_pct: 0.28
          },
          memory: {
            usage: 1024,
            working_set: 2048
          },
          filesystem: event.dig(:stats, -1, :filesystem),
          diskio: event.dig(:stats, -1, :diskio),
          network: event.dig(:stats, -1, :network)
        }
      ))
      expect {
        subject.send_container_stats(event)
      }.to change{ queue.length }.by(1)
    end

    it 'does not fail on missing cpu stats' do
      event[:stats][-1][:cpu][:usage][:per_cpu_usage] = nil
      expect(subject.wrapped_object).to receive(:send_statsd_metrics).with('weave', hash_including({
          id: 'a675a5cd5f36ba747c9495f3dbe0de1d5f388a2ecd2aaf5feb00794e22de6c5e',
          spec: 'spec',
          cpu: {
            usage: 100000000,
            usage_pct: 0.28
          },
          memory: {
            usage: 1024,
            working_set: 2048
          },
          filesystem: event.dig(:stats, -1, :filesystem),
          diskio: event.dig(:stats, -1, :diskio),
          network: event.dig(:stats, -1, :network)
        }
      ))
      expect {
        subject.send_container_stats(event)
      }.to change{ queue.length }.by(1)
    end
  end

end
