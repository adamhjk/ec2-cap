#
# Author:: Adam Jacob (<adam@hjksolutions.com>)
# Copyright:: Copyright (c) 2008 HJK Solutions, LLC
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

#
# Manage EC2 Instances
#

$: << File.join(File.dirname(__FILE__))
require File.join(File.dirname(__FILE__), '..', '..', 'config', 'ec2.rb')
require 'rubygems'
require 'right_aws'
require '/srv/iclassify/lib/iclassify'

HOST_TYPE_DIR = File.join(File.dirname(__FILE__), '..', '..', 'config', 'ec2')

default_run_options[:pty] = true

if ENV.has_key?('IC_SERVER')
  set(:ic_server, ENV["IC_SERVER"])
else
  set(:ic_server, IC_SERVER)
end

set(:user) { ENV.has_key?('USER') ? ENV['USER'] : Capistrano::CLI.ui.ask("User: ") } unless exists?(:user)

set(:master) do 
  OPS_MASTER
end unless exists?(:master)

role(:master) do 
  master
end

role(:monitoring) do
  search_results = Array.new
  @ic.search("puppet_class:operations-monitoring").each do |node|
    search_results << node.attrib?('fqdn')
  end
  search_results
end

@ic = IClassify::Client.new(ic_server, user, password)
@dns_names = Array.new
@nodes = Array.new
@instance_ids = Array.new
set :ec2, RightAws::Ec2.new(AWS_ACCESS_KEY, AWS_SECRET_KEY)

role(:new_nodes) { @dns_names }

desc "Terminate EC2 Instances: requires iClassify QUERY"
task :terminate do
  logger.info("Terminating instances")
  terminate_list = Array.new
  @ic.search(ENV['QUERY']).each do |node|
    logger.info("About to terminate #{node.attrib?('fqdn')} id #{node.attrib?('ec2-instance-id')}")
    @dns_names << node.attrib?("fqdn")
    @nodes << node
    terminate_list << node.attrib?('ec2-instance-id')
  end
  raise ArgumentError, "No nodes found for #{ENV['QUERY']}!" unless @nodes.length > 0
  answer = Capistrano::CLI.ui.ask "Type 'yes' if you really want to terminate: " unless ENV["NO_PROMPT"]
  if answer == "yes"
    remove_from_iclassify
    clean_ssl_certs
    update_monitoring
    results = ec2.terminate_instances(terminate_list)
    results.each do |ti|
      logger.info("#{ti[:aws_instance_id]}: #{ti[:aws_shutdown_state]}")
    end
    logger.info("Instances terminated!")
  else
    logger.info("Not terminating instances!  You typed: #{answer}!")
  end

end

task :clean_ssl_certs, :roles => [ :master ] do
  logger.info("Cleaning up SSL Certificates")
  @dns_names.each do |fqdn|
    sudo("puppetca --clean #{fqdn}")
  end
end

task :remove_from_iclassify do
  @nodes.each do |node|
    logger.info("Removing #{node.attrib?('fqdn')} from iClassify")
    @ic.delete_node(node)
  end
end

task :update_monitoring, :roles => [ :monitoring ] do
  logger.info("Updating the monitoring servers to ensure no false alarms")
  sudo("puppetd --onetime --verbose --ignorecache --no-daemonize --server #{master}")
end

desc "Launch EC2 Instances: Requires master, host_type and number"
task :create do
  set(:host_type) do
    Capistrano::CLI.ui.ask "Host Type: "
  end unless exists?(:host_type)

  if File.exist?(File.join(HOST_TYPE_DIR, "#{host_type}.rb"))
    load File.join(HOST_TYPE_DIR, "#{host_type}.rb")
  else
    raise ArgumentError, "Cannot find EC2 Config: #{File.join(HOST_TYPE_DIR, host_type + '.rb')}"
  end
  
  # Allow for the overriding of the EC2_DATA with command line -S switches
  EC2_DATA.each do |key, value|
    if exists?(key.to_sym)
      EC2_DATA[key] = fetch(key.to_sym)
    end
  end
  
  set(:number, 1) unless exists?(:number)
  
  if EC2_DATA[:elastic_ip] != nil && number.to_i > 1
    raise ArgumentError, "You can't launch more than one instance with an elastic ip (#{number})!"
  end
  
  if EC2_DATA[:elastic_ip]
    ENV["QUERY"] = "ec2-public-ipv4:#{EC2_DATA[:elastic_ip]}" 
    begin
      terminate
    rescue
      logger.info("No node to terminate")
    end
    ec2.disassociate_address(EC2_DATA[:elastic_ip]) 
    @dns_names = Array.new
    @nodes = Array.new
  end
  
  logger.info("Launching instance(s)")
  launched_instances = ec2.run_instances(EC2_DATA[:ami], number, number, EC2_DATA[:groups], EC2_DATA[:keypair], '', nil, EC2_DATA[:instance_type], nil, nil, EC2_DATA[:availability_zone])
  booting = true
  while booting
    instance_status = ec2.describe_instances(launched_instances.collect { |i| i[:aws_instance_id] })
    finished = 0
    instance_status.each do |i|
      logger.debug("#{i[:aws_instance_id]}: #{i[:aws_state]}")
      if i[:aws_state] == "running"
        @dns_names << i[:dns_name] unless @dns_names.detect { |n| n == i[:dns_name] }
        @instance_ids << i[:aws_instance_id] unless @instance_ids.detect { |n| n == i[:aws_instance_id] }
        finished += 1
      end
    end
    booting = false if finished == launched_instances.length
    sleep 10 unless booting == false
  end
  logger.info("Instances launched: ")
  @dns_names.each do |name|
    logger.info("  - #{name}")
  end
  logger.info("Sleeping 20 seconds to allow the system(s) to finish booting")
  sleep(20)
  if EC2_DATA[:elastic_ip]
    ec2.associate_address(@instance_ids.first, EC2_DATA[:elastic_ip])
    set_hostname
  end
  if EC2_DATA[:volumes]
    EC2_DATA[:volumes].each do |vol_id, device|
      logger.info("Attaching volume")
      ec2.attach_volume(vol_id, @instance_ids.first, device)
    end
  end
  build_ephemeral_store
  update_resolv_conf
  update_icagent_recipes
  register_icagent
  classify_nodes
  generate_certificate
  sign_certificate
  puppet
  logger.info("Instances running: ")
  @dns_names.each do |name|
    logger.info("#{name}")
  end
end

task :set_hostname, :roles => [ :new_nodes ] do
  put(
    File.read(File.join(File.dirname(__FILE__), '..', '..', 'bootstrap', 'set-ec2-hostname.sh')),
    '/tmp/set-ec2-hostname.sh'
  )
  sudo("chmod a+x /tmp/set-ec2-hostname.sh")
  sudo("/tmp/set-ec2-hostname.sh")
  hjk.load_facts
  @dns_names[0] = facter_fqdn
end

task :update_resolv_conf, :roles => [ :new_nodes ] do
  sudo("perl -pi -e 's/^search.+/search #{RESOLVER_SEARCH_PATH}/' /etc/resolv.conf")
end

task :classify_nodes do
  @dns_names.each do |description|
    description =~ /^(.+?)\..+$/
    hostname = $1
    node = @ic.get_node(hostname)
    node.tags = EC2_DATA[:iclassify_tags]
     EC2_DATA[:iclassify_attribs].each do |name, values|
       exists = node.attribs.detect { |a| a[:name] == name }
       if exists
         exists[:values] = values.kind_of?(Array) ? values : [ values ]
       else
         node.attribs << { :name => name, :values => values.kind_of?(Array) ? values : [ values ] }
       end
     end
     logger.info("Classifying #{node.attrib?('fqdn')} as #{EC2_DATA[:iclassify_tags].join(', ')}")
     puts node.inspect
     @ic.update_node(node)
  end
end

task :update_icagent_recipes, :roles => [ :new_nodes ] do
  sudo("rm -f /srv/icagent/icagent/*")
  Dir[File.join(File.dirname(__FILE__), '..', '..', 'files', 'dists', 'iclassify', 'default', 'icagent', '*.rb')].sort.each do |file|
    basename = File.basename(file)
    logger.debug("Updating #{basename} icagent recipe")
    run("mkdir -p /tmp/icagent")
    put(File.read(file), "/tmp/icagent/#{basename}")
    sudo("cp /tmp/icagent/#{basename} /srv/icagent/icagent/#{basename}")
  end
end

task :build_ephemeral_store, :roles => [ :new_nodes ] do
  logger.info("Building ephemeral store with LVM")
  sudo("apt-get -y install xfsprogs xfsdump xfslibs-dev")
  put(
    File.read(File.join(File.dirname(__FILE__), "..", "..", "bootstrap", "lvm_ephemeral.pl")),
    "/tmp/lvm_ephemeral.pl"
  )
  sudo("chmod 755 /tmp/lvm_ephemeral.pl")
  sudo("/tmp/lvm_ephemeral.pl #{EC2_DATA[:instance_type]}")
end

task :register_icagent, :roles => [ :new_nodes ] do
  sudo("rm -f /srv/icagent/icagent.uuid") # just in case the image is broken
  sudo("/srv/icagent/bin/icagent -d /srv/icagent/icagent -s #{ic_server}")
end

task :generate_certificate, :roles => [ :new_nodes ] do
  begin
    sudo("puppetd --onetime --verbose --ignorecache --no-daemonize --server #{master}")  
  rescue Exception => e
    logger.info("Puppet certificate generated")
  end
end

task :sign_certificate, :roles => [ :master ] do
  @dns_names.each do |name|
    sudo("bash -c 'if [ 1 -eq $(puppetca --list | grep #{name} | wc -l) ]; then puppetca --sign #{name}; fi'")
  end
end

task :puppet, :roles => [ :new_nodes ] do
  sudo("puppetd --onetime --verbose --ignorecache --no-daemonize --server #{master}")
end

# Some handy tasks for non-bootstrap things

task :describe_instances do
  ec2.describe_instances.each do |instance|
    puts <<-EOH
    
fqdn: #{instance[:dns_name]}
instance_id: #{instance[:aws_instance_id]}
state: #{instance[:aws_state]}
instance_type: #{instance[:aws_instance_type]}
availability zone: #{instance[:aws_availability_zone]}
    EOH
  end
end

###
# Helper Methods
###
def load_facts 
  logger.info("Loading Facter facts")
  interfaces = Array.new
  facter_lines = capture("facter")
  facter_lines.split("\n").each do |data|
    data.chomp!
    data =~ /^(.+?) \=\> (.+?)$/
    name = "facter_#{$1}"
    value = "#{$2}"
    logger.debug("Setting #{name} => #{value}")
    set(name.to_sym, value)

    if name =~ /^facter_ipaddress_(.+)$/
      interfaces << value
    end
  end
  set(:facter_interfaces, interfaces)
end
