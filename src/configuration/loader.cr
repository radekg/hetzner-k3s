require "yaml"
require "crest"

require "./main"

require "../hetzner/client"
require "../hetzner/server_type"
require "../hetzner/location"

require "./settings/configuration_file_path"
require "./settings/cluster_name"
require "./settings/kubeconfig_path"
require "./settings/k3s_version"
require "./settings/new_k3s_version"
require "./settings/public_ssh_key_path"
require "./settings/private_ssh_key_path"
require "./settings/networks"
require "./settings/existing_network_name"
require "./settings/node_pool"
require "./settings/node_pool/autoscaling"
require "./settings/node_pool/pool_name"
require "./settings/node_pool/instance_type"
require "./settings/node_pool/location"
require "./settings/node_pool/instance_count"
require "./settings/node_pool/node_labels"
require "./settings/node_pool/node_taints"


class Configuration::Loader
  getter hetzner_client : Hetzner::Client?
  getter errors : Array(String) = [] of String
  getter settings : Configuration::Main

  getter hetzner_client : Hetzner::Client do
    Hetzner::Client.new(settings.resolved_hetzner_token)
  end

  getter public_ssh_key_path do
    Path[settings.public_ssh_key_path].expand(home: true).to_s
  end

  getter private_ssh_key_path do
    Path[settings.private_ssh_key_path].expand(home: true).to_s
  end

  getter kubeconfig_path do
    Path[settings.kubeconfig_path].expand(home: true).to_s
  end

  getter masters_location : String | Nil do
    settings.masters_pool.try &.location
  end

  getter server_types : Array(Hetzner::ServerType) do
    server_types = hetzner_client.server_types

    if server_types.empty?
      puts "Cannot fetch server types with Hetzner API, please try again later"
      exit 1
    end

    server_types
  end

  getter locations : Array(Hetzner::Location) do
    locations = hetzner_client.locations

    if locations.empty?
      puts "Cannot fetch locations with Hetzner API, please try again later"
      exit 1
    end

    locations
  end

  getter new_k3s_version : String?
  getter configuration_file_path : String

  private property server_types_loaded : Bool = false
  private property locations_loaded : Bool = false
  private property allow_token_from_file : Bool = false

  def initialize(@configuration_file_path, @allow_token_from_file, @new_k3s_version)
    expanded_path = Path[configuration_file_path].expand(home: true).to_s
    @settings = Configuration::Main.from_yaml(File.read(expanded_path))

    Settings::ConfigurationFilePath.new(errors, expanded_path).validate

    print_errors unless errors.empty?
  end

  def validate(command)
    print "Validating configuration..."

    Settings::ClusterName.new(errors, settings.cluster_name).validate

    case command
    when :create
      validate_allows_token_from_file
      Settings::KubeconfigPath.new(errors, kubeconfig_path, file_must_exist: false).validate
      Settings::K3sVersion.new(errors, settings.k3s_version).validate
      Settings::PublicSSHKeyPath.new(errors, public_ssh_key_path).validate
      Settings::PrivateSSHKeyPath.new(errors, private_ssh_key_path).validate
      Settings::ExistingNetworkName.new(errors, hetzner_client, settings.existing_network).validate
      Settings::Networks.new(errors, settings.ssh_allowed_networks, "SSH").validate
      Settings::Networks.new(errors, settings.api_allowed_networks, "API").validate
      validate_masters_pool
      validate_worker_node_pools
    when :delete
    when :upgrade
      validate_allows_token_from_file
      Settings::KubeconfigPath.new(errors, kubeconfig_path, file_must_exist: true).validate
      Settings::NewK3sVersion.new(errors, settings.k3s_version, new_k3s_version).validate
    end

    if errors.empty?
      puts "...configuration seems valid."
    else
      print_errors
      exit 1
    end
  end

  private def validate_allows_token_from_file
    if settings.hetzner_token.starts_with?("file://")
      if !allow_token_from_file
        errors << "Hetzner token is set to a path but paths are not allowed, use --allow-token-from-file flag"
        return
      end
    end
  end

  private def validate_masters_pool
    Settings::NodePool.new(
      errors: errors,
      pool: settings.masters_pool,
      pool_type: :masters,
      masters_location: masters_location,
      server_types: server_types,
      locations: locations
    ).validate
  end

  private def validate_worker_node_pools
    if settings.worker_node_pools
      node_pools = settings.worker_node_pools

      unless node_pools.size.positive? || settings.schedule_workloads_on_masters
        errors << "Invalid node pools configuration"
        return
      end

      return if node_pools.size.zero? && settings.schedule_workloads_on_masters

      if node_pools.size.zero?
        errors << "At least one node pool is required in order to schedule workloads"
      else
        worker_node_pool_names = node_pools.map do |node_pool|
          node_pool.name
        end

        if worker_node_pool_names.uniq.size != node_pools.size
          errors << "Each node pool must have an unique name"
        end

        node_pools.map do |worker_node_pool|
          Settings::NodePool.new(
            errors: errors,
            pool: worker_node_pool,
            pool_type: :workers,
            masters_location: masters_location,
            server_types: server_types,
            locations: locations
          ).validate
        end
      end
    elsif !settings.schedule_workloads_on_masters
      errors << "settings.worker_node_pools is required if workloads cannot ve scheduled on masters"
    end
  end

  private def print_errors
    return if errors.empty?

    puts "\nSome information in the configuration file requires your attention:"

    errors.each do |error|
      STDERR.puts "  - #{error}"
    end

    exit 1
  end
end
