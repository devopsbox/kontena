require_relative '../logging'
require_relative '../helpers/node_helper'
require_relative '../helpers/iface_helper'

module Kontena::NetworkAdapters
  class Weave
    include Celluloid
    include Celluloid::Notifications
    include Kontena::Helpers::NodeHelper
    include Kontena::Helpers::IfaceHelper
    include Kontena::Logging

    WEAVE_VERSION = ENV['WEAVE_VERSION'] || '1.7.2'
    WEAVE_IMAGE = ENV['WEAVE_IMAGE'] || 'weaveworks/weave'
    WEAVEEXEC_IMAGE = ENV['WEAVEEXEC_IMAGE'] || 'weaveworks/weaveexec'

    DEFAULT_NETWORK = 'kontena'.freeze

    def initialize(autostart = true)
      @images_exist = false
      @started = false
      @ipam_running = false

      info 'initialized'
      subscribe('agent:node_info', :on_node_info)
      subscribe('ipam:start', :on_ipam_start)
      async.ensure_images if autostart
    end

    # @return [String]
    def weave_version
      WEAVE_VERSION
    end

    # @return [String]
    def weave_image
      "#{WEAVE_IMAGE}:#{WEAVE_VERSION}"
    end

    # @return [String]
    def weave_exec_image
      "#{WEAVEEXEC_IMAGE}:#{WEAVE_VERSION}"
    end

    # @param [Docker::Container] container
    # @return [Boolean]
    def adapter_container?(container)
      adapter_image?(container.config['Image'])
    rescue Docker::Error::NotFoundError
      false
    end

    # @param [String] image
    # @return [Boolean]
    def adapter_image?(image)
      image.to_s.include?(WEAVEEXEC_IMAGE)
    rescue
      false
    end

    def router_image?(image)
      image.to_s == "#{WEAVE_IMAGE}:#{WEAVE_VERSION}"
    rescue
      false
    end

    # @return [Boolean]
    def running?
      weave = Docker::Container.get('weave') rescue nil
      return false if weave.nil?
      weave.running? && ipam_running?
    end

    def ipam_running?
      @ipam_running
    end

    # @return [Boolean]
    def images_exist?
      @images_exist == true
    end

    # @return [Boolean]
    def already_started?
      @started == true
    end

    # @param [Hash] opts
    def modify_create_opts(opts)
      ensure_weave_wait

      image = Docker::Image.get(opts['Image'])
      image_config = image.info['Config']
      cmd = []
      if opts['Entrypoint']
        if opts['Entrypoint'].is_a?(Array)
          cmd = cmd + opts['Entrypoint']
        else
          cmd = cmd + [opts['Entrypoint']]
        end
      end
      if !opts['Entrypoint'] && image_config['Entrypoint'] && image_config['Entrypoint'].size > 0
        cmd = cmd + image_config['Entrypoint']
      end
      if opts['Cmd'] && opts['Cmd'].size > 0
        if opts['Cmd'].is_a?(Array)
          cmd = cmd + opts['Cmd']
        else
          cmd = cmd + [opts['Cmd']]
        end
      elsif image_config['Cmd'] && image_config['Cmd'].size > 0
        cmd = cmd + image_config['Cmd']
      end
      opts['Entrypoint'] = ['/w/w']
      opts['Cmd'] = cmd

      modify_host_config(opts)
      opts
    end

    # @param [Hash] opts
    def modify_network_opts(opts)
      opts['Labels']['io.kontena.container.overlay_cidr'] = @ipam_client.reserve_address('kontena')
      opts['Labels']['io.kontena.container.overlay_network'] = 'kontena'

      opts
    end

    # @param [Hash] opts
    def modify_host_config(opts)
      host_config = opts['HostConfig'] || {}
      host_config['VolumesFrom'] ||= []
      host_config['VolumesFrom'] << "weavewait-#{WEAVE_VERSION}:ro"
      dns = interface_ip('docker0')
      if dns && host_config['NetworkMode'].to_s != 'host'.freeze
        host_config['Dns'] = [dns]
        host_config['DnsSearch'] = [opts['Domainname']]
      end
      opts['HostConfig'] = host_config
    end

    # @param [Array<String>] cmd
    # @yield [line] Each line of output
    def exec(cmd, &block)
      begin
        container = Docker::Container.create(
          'Image' => weave_exec_image,
          'Cmd' => cmd,
          'Volumes' => {
            '/var/run/docker.sock' => {},
            '/host' => {}
          },
          'Labels' => {
            'io.kontena.container.skip_logs' => '1'
          },
          'Env' => [
            'HOST_ROOT=/host',
            "VERSION=#{WEAVE_VERSION}",
            "WEAVE_DEBUG=#{ENV['WEAVE_DEBUG']}",
          ],
          'HostConfig' => {
            'Privileged' => true,
            'NetworkMode' => 'host',
            'PidMode' => 'host',
            'Binds' => [
              '/var/run/docker.sock:/var/run/docker.sock',
              '/:/host'
            ]
          }
        )
        retries = 0
        response = {}
        begin
          response = container.tap(&:start).wait
        rescue Docker::Error::NotFoundError => exc
          error exc.message
          return false
        rescue => exc
          retries += 1
          error exc.message
          sleep 0.5
          retry if retries < 10

          error exc.message
          return false
        end

        status_code = response["StatusCode"]
        output = container.streaming_logs(stdout: true, stderr: true)

        if status_code != 0
          error "weaveexec exit #{status_code}: #{cmd}\n#{output}"
          return false
        elsif block
          debug "weaveexec stream: #{cmd}"
          output.each_line &block
          return true
        else
          debug "weaveexec ok: #{cmd}\n#{output}"
          return true
        end
      ensure
        container.delete(force: true, v: true) if container
      end
    end

    # List network information for container(s)
    #
    # @param [Array<String>] what for given Docker IDs, 'weave:expose', or all
    # @yield [name, mac, *cidrs]
    # @yieldparam [Array<String>] cidrs
    def ps(*what)
      self.exec(['--local', 'ps', *what]) do |line|
        yield *line.split()
      end
    end

    # Configure given address on host weave bridge.
    # Also configures iptables rules for the subnet
    #
    # @param [String] cidr '10.81.0.X/16' host node overlay_cidr
    def expose(cidr)
      self.exec(['--local', 'expose', "ip:#{cidr}"])
    end

    # De-configure given address on host weave bridge.
    # Aslo removes iptables rules for the subnet
    #
    # @param [String] cidr '10.81.0.X/16' host node overlay_cidr
    def hide(cidr)
      self.exec(['--local', 'hide', cidr])
    end

    # Configure ethwe interface with cidr for given container
    #
    # @param [String] id Docker ID
    # @param [String] cidr Overlay '10.81.X.Y/16' CIDR
    def attach(id, cidr)
      self.exec(['--local', 'attach', cidr, '--rewrite-hosts', id])
    end

    # De-configure ethwe interface with cidr for given container
    #
    # @param [String] id Docker ID
    # @param [String] cidr Overlay '10.81.X.Y/16' CIDR
    def detach(id, cidr)
      self.exec(['--local', 'detach', cidr, id])
    end

    # @param [String] topic
    # @param [Hash] info
    def on_node_info(topic, info)
      async.start(info)
    end

    def on_ipam_start(topic, data)
      @ipam_client = IpamClient.new
      ensure_default_pool
      Celluloid::Notifications.publish('network:ready', nil)
      @ipam_running = true
    end

    # Ensure that the host weave bridge is exposed using the given CIDR address,
    # and only the given CIDR address
    #
    # @param [String] cidr '10.81.0.X/16'
    def ensure_exposed(cidr)
      # configure new address
      # these will be added alongside any existing addresses
      if self.expose(cidr)
        info "Exposed host node at cidr=#{cidr}"
      else
        error "Failed to expose host node at cidr=#{cidr}"
      end

      # cleanup any old addresses
      self.ps('weave:expose') do |name, mac, *cidrs|
        cidrs.each do |exposed_cidr|
          if exposed_cidr != cidr
            warn "Migrating host node from cidr=#{exposed_cidr}"
            self.hide(exposed_cidr)
          end
        end
      end
    end

    def ensure_default_pool()
      info 'network and ipam ready, ensuring default network existence'
      @default_pool = @ipam_client.reserve_pool('kontena', '10.81.0.0/16', '10.81.128.0/17')
    end

    # @param [Hash] info
    def start(info)
      sleep 1 until images_exist?

      weave = Docker::Container.get('weave') rescue nil
      if weave && config_changed?(weave, info)
        weave.delete(force: true)
      end

      weave = nil
      peer_ips = info['peer_ips'] || []
      trusted_subnets = info.dig('grid', 'trusted_subnets')
      until weave && weave.running? do
        exec_params = [
          '--local', 'launch-router', '--ipalloc-range', '', '--dns-domain', 'kontena.local',
          '--password', ENV['KONTENA_TOKEN']
        ]
        exec_params += ['--trusted-subnets', trusted_subnets.join(',')] if trusted_subnets
        self.exec(exec_params)
        weave = Docker::Container.get('weave') rescue nil
        wait = Time.now.to_f + 10.0
        sleep 0.5 until (weave && weave.running?) || (wait < Time.now.to_f)

        if weave.nil? || !weave.running?
          self.exec(['--local', 'reset'])
        end
      end

      attach_router unless interface_ip('weave')
      connect_peers(peer_ips)
      info "using trusted subnets: #{trusted_subnets.join(',')}" if trusted_subnets && !already_started?
      post_start(info)

      Celluloid::Notifications.publish('network_adapter:start', info) unless already_started?

      @started = true
      info
    rescue => exc
      error "#{exc.class.name}: #{exc.message}"
      debug exc.backtrace.join("\n")
    end

    def attach_router
      info "attaching router"
      self.exec(['--local', 'attach-router'])
    end

    # @param [Array<String>] peer_ips
    def connect_peers(peer_ips)
      if peer_ips.size > 0
        self.exec(['--local', 'connect', '--replace'] + peer_ips)
        info "router connected to peers #{peer_ips.join(', ')}"
      else
        info "router does not have any known peers"
      end
    end

    # @param [Hash] info
    def post_start(info)
      if info['node_number']
        ensure_exposed("10.81.0.#{info['node_number']}/16")
      end
    end

    # @param [Docker::Container] weave
    # @param [Hash] config
    def config_changed?(weave, config)
      return true if weave.config['Image'].split(':')[1] != WEAVE_VERSION
      cmd = Hash[*weave.config['Cmd'].flatten(1)]
      return true if cmd['--trusted-subnets'] != config.dig('grid', 'trusted_subnets').to_a.join(',')

      false
    end

    # Attach container to weave with given CIDR address
    #
    # @param [String] container_id
    # @param [String] overlay_cidr '10.81.X.Y/16'
    def attach_container(container_id, cidr)
      info "Attach container=#{container_id} at cidr=#{cidr}"

      self.attach(container_id, cidr)
    end

    # Attach container to weave with given CIDR address, first detaching any mismatching addresses
    #
    # @param [String] container_id
    # @param [String] overlay_cidr '10.81.X.Y/16'
    def migrate_container(container_id, cidr)
      info "Migrate container=#{container_id} to cidr=#{cidr}"

      # first remove any existing addresses
      # this is required, since weave will not attach if the address already exists, but with a different netmask
      self.ps(container_id) do |name, mac, *cidrs|
        debug "Migrate check: name=#{name} with cidrs=#{cidrs}"

        cidrs.each do |attached_cidr|
          if cidr != attached_cidr
            warn "Migrate container=#{container_id} from cidr=#{attached_cidr}"
            self.detach(container_id, attached_cidr)
          end
        end
      end

      # attach with the correct address
      self.attach_container(container_id, cidr)
    end

    def detach_network(event)
      overlay_cidr = event.Actor.attributes['io.kontena.container.overlay_cidr']
      overlay_network = event.Actor.attributes['io.kontena.container.overlay_network']
      if overlay_cidr
        debug "releasing weave network address for container #{event.id}"
        @ipam_client.release_address(overlay_network, overlay_cidr)
      end
    end

    private

    def ensure_images
      images = [
        weave_image,
        weave_exec_image
      ]
      images.each do |image|
        unless Docker::Image.exist?(image)
          info "pulling #{image}"
          Docker::Image.create({'fromImage' => image})
          sleep 1 until Docker::Image.exist?(image)
          info "image #{image} pulled "
        end
      end
      @images_exist = true
    end


    def ensure_weave_wait
      sleep 1 until images_exist?

      container_name = "weavewait-#{WEAVE_VERSION}"
      weave_wait = Docker::Container.get(container_name) rescue nil
      unless weave_wait
        Docker::Container.create(
          'name' => container_name,
          'Image' => weave_exec_image,
          'Entrypoint' => ['/bin/false'],
          'Labels' => {
            'weavevolumes' => ''
          },
          'Volumes' => {
            '/w' => {},
            '/w-noop' => {},
            '/w-nomcast' => {}
          }
        )
      end
    end

  end
end
