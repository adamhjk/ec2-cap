#!/bin/bash
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

# Set the hostname
HOSTNAME=`curl http://169.254.169.254/latest/meta-data/public-hostname`
IPV4=`curl http://169.254.169.254/latest/meta-data/public-ipv4`
echo "$IPV4 $HOSTNAME" >> /etc/hosts
hostname $HOSTNAME
echo $HOSTNAME > /etc/hostname

# Restart sysklogd
/usr/sbin/invoke-rc.d sysklogd restart
