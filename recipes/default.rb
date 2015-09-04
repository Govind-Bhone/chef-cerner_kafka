# coding: UTF-8
# Cookbook Name:: cerner_kafka
# Recipe:: default

# Create an array for storing errors we should verify before doing anything
errors = Array.new

# Verify either node["kafka"]["brokers"] or node["kafka"]["server.properties"]["broker.id"] is set properly
ruby_block 'assert broker and zookeeper lists are correct' do # ~FC014
  block_name 'attribute_assertions'
  block do
    if (node['kafka']['brokers'].to_a.empty?) && !node['kafka']['server.properties'].has_key?('broker.id')
      errors.push 'node[:kafka][:brokers] or node[:kafka][:server.properties][:broker.id] must be set properly'
    elsif !node['kafka']['server.properties'].has_key?('broker.id')
      # Generate brokerId for Kafka (uses the index of the brokers list to figure out which ID this broker should have). We add 1 to ensure
      # we have a positive (non zero) number
      brokerId = ( node['kafka']['brokers'].to_a.index do |broker|
          broker == node["fqdn"] || broker == node["ipaddress"] || broker == node["hostname"]
        end
      )
      if brokerId.nil?
        errors.push "Unable to find #{node['fqdn']}, #{node['ipaddress']} or "\
                    "#{node['hostname']} in node[:kafka][:brokers] : #{node['kafka']['brokers']}"
      else
        brokerId += 1
        node.default['kafka']['server.properties']['broker.id'] = brokerId
      end
    end

    # Verify we have a list of zookeeper instances
    if (node['kafka']['zookeepers'].to_a.empty?) && !node['kafka']['server.properties'].has_key?('zookeeper.connect')
      errors.push 'node[:kafka][:zookeepers] or node[:kafka][:server.properties][:zookeeper.connect] was not set properly'
    elsif !node['kafka']['server.properties'].has_key?('zookeeper.connect')
      zk_connect = node['kafka']['zookeepers'].to_a.join ','
      zk_connect += node["kafka"]["zookeeper_chroot"] unless node["kafka"]["zookeeper_chroot"].nil?
      node.default['kafka']['server.properties']['zookeeper.connect'] = zk_connect
    end

    # Raise an exception if there are any problems
    raise "Unable to run kafka::default : \n  -#{errors.join "\n  -"}]\n" unless errors.empty?
  end
end

# Tells log4j to write logs into the /var/log/kafka directory
node.default["kafka"]["log4j.properties"]["log4j.appender.kafkaAppender.File"] = File.join node["kafka"]["log_dir"], "server.log"
node.default["kafka"]["log4j.properties"]["log4j.appender.stateChangeAppender.File"] = File.join node["kafka"]["log_dir"], "state-change.log"
node.default["kafka"]["log4j.properties"]["log4j.appender.requestAppender.File"] = File.join node["kafka"]["log_dir"], "kafka-request.log"
node.default["kafka"]["log4j.properties"]["log4j.appender.controllerAppender.File"] = File.join node["kafka"]["log_dir"], "controller.log"

# Set default limits

# We currently ignore FC047 - http://www.foodcritic.io/#FC047) due to a bug in foodcritic giving false
# positives (https://github.com/acrmp/foodcritic/issues/225)
node.default["ulimit"]["users"][node["kafka"]["user"]]["filehandle_limit"] = 32768 # ~FC047
node.default["ulimit"]["users"][node["kafka"]["user"]]["process_limit"] = 1024 # ~FC047

include_recipe "ulimit"

include_recipe "cerner_kafka::install"

# Ensure the Kafka broker log (kafka data) directories exist
node["kafka"]["server.properties"]["log.dirs"].split(",").each do |log_dir|
  directory log_dir do
    action :create
    owner node["kafka"]["user"]
    group node["kafka"]["group"]
    mode 00700
    recursive true
  end
end

# Create init.d script for kafka
# We need to land this early on in case our resources attempt to notify the service resource to stop/start/restart immediately
template "/etc/init.d/kafka" do
  source "kafka_initd.erb"
  owner "root"
  group "root"
  mode  00755
  notifies :restart, "service[kafka]"
end

# Configure kafka properties
%w[server.properties log4j.properties].each do |template_file|
  template "#{node["kafka"]["install_dir"]}/config/#{template_file}" do
    source  "key_equals_value.erb"
    owner node["kafka"]["user"]
    group node["kafka"]["group"]
    mode  00755
    variables(
      lazy {
        { :properties => node["kafka"][template_file].to_hash }
      }
    )
    notifies :restart, "service[kafka]"
  end
end

# Start/Enable Kafka
service "kafka" do
  action [:enable, :start]
end
