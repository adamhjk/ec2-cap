#!/usr/bin/perl
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
# Create an LVM based ephemeral storage
#

# To add a new instance partition scheme, add it to the dispatch table below
# and create a "create_foo" subroutine, probably based on create_large or create_xlarge
%dispatch = (
  "m1.small" => \&create_small,
  "m1.large" => \&create_large,
  "m1.xlarge" => \&create_xlarge,
);

unless ($ARGV[0]) {
  die "You must provide one of: " . join(", ", keys(%dispatch));
}

my $already_done = 0;
open(FSTAB, "<", "/etc/fstab") or die "Cannot open /etc/fstab";
while (<FSTAB>) {
  $already_done = 1 if /ephemeral/;
}
close(FSTAB);
if ($already_done) {
  print "Already converted to LVM\n";
  exit 0;
} else {
  run_command("mkdir /tmp/old-mount");
  run_command("cp -r /mnt/* /tmp/old-mount");
  run_command("umount /mnt");
  $dispatch{$ARGV[0]}->();
  run_command("mount /mnt");
  run_command("cp -r /tmp/old-mount/* /mnt");
  exit 0;
}

sub create_small {
  run_command("pvcreate /dev/sda2");
  run_command("vgcreate ephemeral /dev/sda2");
  run_command("lvcreate -l 30000 ephemeral -n mnt");
  run_command("mkfs.ext3 -q /dev/ephemeral/mnt");
  run_command("perl -pi -e 's!/dev/sda2!/dev/ephemeral/mnt!g' /etc/fstab");
}

sub create_large {
  @partitions = ( "/dev/sdb", "/dev/sdc" );
  foreach my $thing (@partitions) {
    run_command("pvcreate $thing");
  }
  run_command("vgcreate ephemeral @partitions");
  run_command("lvcreate -i 2 -L 800G -n mnt ephemeral");
  run_command("mkfs.xfs /dev/ephemeral/mnt");
  run_command("perl -pi -e 's!/dev/sdb.+/mnt.+ext3!/dev/ephemeral/mnt /mnt xfs!g' /etc/fstab");
}

sub create_xlarge {
  @partitions = ( "/dev/sdb", "/dev/sdc", "/dev/sdd", "/dev/sde" );
  foreach my $thing (@partitions) {
    run_command("pvcreate $thing");
  }
  run_command("vgcreate ephemeral @partitions");
  run_command("lvcreate -i 4 -L 1.3T -n mnt ephemeral");
  run_command("mkfs.xfs /dev/ephemeral/mnt");
  run_command("perl -pi -e 's!/dev/sdb.+/mnt.+ext3!/dev/ephemeral/mnt /mnt xfs!g' /etc/fstab");
}

sub run_command {
  my $cmd = shift;
  system($cmd);
  if ($? == -1) {
    die "failed to execute: $!\n";
  } elsif ($? & 127) {
    die sprintf "child died with signal %d, %s coredump\n", ($? & 127),  ($? & 128) ? "with" : "without";
  } else {
    my $exit_value = $? >> 8;
    if ($exit_value != 0) {
      die sprintf "child exited with value %d\n", $? >> 8;
    }
  }
}
