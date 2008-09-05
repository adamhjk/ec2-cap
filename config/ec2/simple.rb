#
# An EC2 Instance Type

EC2_DATA = {
  # The AMI to use
  :ami => 'ami-1fe10576',
  # The EC2 firewall groups it should be in
  :groups => [ 'default' ],
  # The root keypair to use
  :keypair => 'gsg-keypair',
  # The availability zone - use nil for the default
  :availability_zone => nil,
  # The instance type
  :instance_type => 'm1.small',
  # An array of iclassify tags you want these instances to have
  :iclassify_tags => [ 'base' ],
  # A hash of any custom attributes you want these instances to have
  :iclassify_attribs => {},
  # A hash of EBS volumes to expose as a given device
  # "vol-af20c56" => "/dev/sdh", for example
  :volumes => nil, 
  # The elastic IP to assign
  :elastic_ip => nil
}
