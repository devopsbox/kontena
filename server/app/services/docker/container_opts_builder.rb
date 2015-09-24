module Docker
  class ContainerOptsBuilder

    ##
    # @param [GridService] grid_service
    # @param [Container] container
    # @return [Hash]
    def self.build_opts(grid_service, container)
      docker_opts = { 'Image' => grid_service.image_name }
      docker_opts['name'] = container.name
      docker_opts['Hostname'] = "#{container.name}.kontena.local"
      docker_opts['User'] = grid_service.user if grid_service.user
      docker_opts['Cmd'] = grid_service.cmd if grid_service.cmd
      docker_opts['Entrypoint'] = grid_service.entrypoint if grid_service.entrypoint
      docker_opts['Env'] = self.build_linked_services_env_vars(grid_service)
      docker_opts['Env'] += grid_service.env if grid_service.env
      docker_opts['ExposedPorts'] = self.exposed_ports(grid_service.ports) if grid_service.ports
      docker_opts['Volumes'] = self.build_volumes(grid_service) if grid_service.stateless? && grid_service.volumes
      docker_opts['Labels'] = self.build_labels(grid_service, container)

      host_config = {}
      host_config['RestartPolicy'] = {
          'Name' => 'always'
      }
      host_config['CpuShares'] = grid_service.cpu_shares if grid_service.cpu_shares
      host_config['Memory'] = grid_service.memory if grid_service.memory
      host_config['MemorySwap'] = grid_service.memory_swap if grid_service.memory_swap
      host_config['Privileged'] = grid_service.privileged if grid_service.privileged
      host_config['CapAdd'] = grid_service.cap_add if grid_service.cap_add && grid_service.cap_add.size > 0
      host_config['CapDrop'] = grid_service.cap_drop if grid_service.cap_drop && grid_service.cap_drop.size > 0

      bind_volumes = self.build_bind_volumes(grid_service)
      if bind_volumes.size > 0
        host_config['Binds'] = bind_volumes
      end
      docker_opts['PortBindings'] = port_bindings(grid_service.ports) if grid_service.ports

      docker_opts['HostConfig'] = host_config
      docker_opts
    end

    ##
    # @param [GridService] grid_service
    # @param [String] container_name
    # @param [String] image
    def self.build_volume_opts(grid_service, container_name, image)
      {
        'Image' => image,
        'name' => "#{container_name}-volumes",
        'Entrypoint' => '/bin/sh',
        'Volumes' => self.build_volumes(grid_service),
        'Cmd' => ['echo', 'Data only container'],
        'Env' => [
          "KONTENA_SERVICE_ID=#{grid_service.id.to_s}"
        ]
      }
    end

    ##
    # @param [GridService] grid_service
    # @return [Array]
    def self.build_linked_services_env_vars(grid_service)
      result = []

      grid_service.grid_service_links.each do |link|
        linked_service = link.linked_grid_service
        image = Image.find_by(name: linked_service.image_name)
        next unless image
        containers_count = linked_service.containers.size
        linked_service.containers.each_with_index do |container, index|
          container_index = containers_count > 1 ? "_#{index + 1}" : ''
          link_alias = "#{link.alias.upcase.sub("-", "_")}#{container_index}"
          ip_address = container.network_settings['ip_address']
          image.exposed_ports.each do |port|
            result << "#{link_alias}_PORT_#{port['port']}_#{port['protocol'].upcase}=#{port['protocol']}://#{ip_address}:#{port['port']}"
            result << "#{link_alias}_PORT_#{port['port']}_#{port['protocol'].upcase}_ADDR=#{ip_address}"
            result << "#{link_alias}_PORT_#{port['port']}_#{port['protocol'].upcase}_PORT=#{port['port']}"
            result << "#{link_alias.upcase}_PORT_#{port['port']}_#{port['protocol'].upcase}_PROTO=#{port['protocol']}"
          end

          result += container.env.map{|env| key, value = env.split('='); "#{link_alias}_ENV_#{key}=#{value}"}
        end
      end
      result
    end

    ##
    # @param [Array<Hash>]
    # @return [Hash]
    def self.exposed_ports(ports)
      exposed_ports = {}
      ports.each do |p|
        exposed_ports["#{p['container_port']}/#{p['protocol']}"] = {}
      end
      exposed_ports
    end

    ##
    # @param [GridService] grid_service
    # @return [Array]
    def self.build_env(grid_service)
      env = grid_service.env || []
      env << "KONTENA_SERVICE_ID=#{grid_service.id.to_s}"
      env
    end

    ##
    # @param [GridService] grid_service
    # @param [Container] container
    # @return [Hash]
    def self.build_labels(grid_service, container)
      labels = {
        'io.kontena.container.name' => container.name,
        'io.kontena.service.id' => grid_service.id.to_s,
        'io.kontena.service.name' => grid_service.name.to_s,
        'io.kontena.grid.name' => grid_service.grid.try(:name)
      }
      labels
    end

    ##
    # @param [GridService] grid_service
    # @return [Hash]
    def self.build_volumes(grid_service)
      volumes = {}
      grid_service.volumes.each do |vol|
        vol, _ = vol.split(':')
        volumes[vol] = {}
      end
      volumes
    end

    ##
    # @param [GridService] grid_service
    # @return [Array]
    def self.build_bind_volumes(grid_service)
      volumes = []
      grid_service.volumes.each do |vol|
        volumes << vol if vol.include?(':')
      end
      volumes
    end

    ##
    # @param [Array<Hash>] ports
    # @return [Hash]
    def self.port_bindings(ports)
      bindings = {}
      ports.each do |p|
        bindings["#{p['container_port']}/#{p['protocol']}"] = [{'HostPort' => p['node_port'].to_s}]
      end
      bindings
    end
  end
end