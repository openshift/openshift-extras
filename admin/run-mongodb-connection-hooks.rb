#!/usr/bin/env oo-ruby

#--
# Copyright 2012 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#++

require 'time'

require "#{ENV['OPENSHIFT_BROKER_DIR'] || '/var/www/openshift/broker'}/config/environment"
include AdminHelper

# Disable analytics for admin scripts
Rails.configuration.analytics[:enabled] = false
Rails.configuration.msg_broker[:rpc_options][:disctimeout] = 20
Rails.configuration.msg_broker[:rpc_options][:timeout] = 600

trap("INT") do
  print_message "#{$0} Interrupted", true
  exit 1
end


current_time = Time.now.utc
puts "Started at: #{current_time}"
start_time = (current_time.to_f * 1000).to_i

apps=Application.elem_match(component_instances: { cartridge_name: "mongodb-2.4" })
apps.each do |app|
  puts "Running connection hooks for application named #{app.canonical_name}, owned by user #{CloudUser.find_by(_id: app.owner_id).login}"
  resultio=app.run_connection_hooks
  if resultio.exitcode != 0
    print_message "An error occurred: #{resultio.to_s}"
  end
end

end_time = Time.now.utc
puts "\nFinished at: #{end_time}"
total_time = (end_time.to_f * 1000).to_i - start_time
puts "Total time: #{total_time.to_f/1000}s"
if $total_errors == 0
  print_message "SUCCESS", true
  errcode = 0
else
  print_message "FAILED", true
  errcode = 1
end
exit errcode
