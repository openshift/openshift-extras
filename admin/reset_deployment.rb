#!/usr/bin/env oo-ruby
#
# THIS SCRIPT DESTROYS OPENSHIFT STATE INCLUDING USERS AND APPS.
# The purpose is to do this cleanly, leaving your deployment intact for
# future use. All OpenShift users and applications will be removed from MongoDB.
# Districts are the only thing left intact, and they are re-initialized
# with a full set of UIDs.
#
# To do so:
# 1. Put broker(s) in maintenance mode.
# 2. Run this script on one broker.
# 3. On all nodes, delete all gears with:
#    # cd /var/lib/openshift; for gear in *; do oo-devel-node app-destroy -c $gear; done
#    This *should* remove all of the gears from the node; but to see if any vestiges remain:
#    # grep 'OpenShift guest' /etc/passwd | cut -d: -f 1
#    Delete any that remain with "userdel -r <gear>"
# 4. Take broker(s) out of maintenance mode.
#
# This script DOES NOT remove existing DNS records. It probably could with a little work.

DROP_COLLECTIONS = [:applications, :authorizations, :cloud_users, :domains, :locks, :usage, :usage_records ]

# Load the broker rails environment.
begin
  require "/var/www/openshift/broker/config/environment"
  # Disable analytics for admin scripts
  Rails.configuration.analytics[:enabled] = false
rescue Interrupt
  puts "Interrupted; exiting."
  exit 1
rescue Exception => e
  puts <<-"FAIL"
    Broker application failed to load:
    #{e.inspect}
    #{e.backtrace}
  FAIL
  exit 1
end

# monkey-patch District with function to reset uids/capacity
class District
  def repop
    first_uid = Rails.configuration.msg_broker[:districts][:first_uid]
    num_uids = Rails.configuration.msg_broker[:districts][:max_capacity]
    self.available_capacity = num_uids
    self.available_uids = (first_uid...first_uid + num_uids).sort_by{rand}
    self.max_uid = first_uid + num_uids - 1
    self.max_capacity = num_uids
    save!
  end
end

puts "clearing out collections"
DROP_COLLECTIONS.each { |coll| District.mongo_session[coll].drop and puts "...cleared #{coll.to_s}" }
puts "resetting the district UIDs available"
District.all.each { |dist| dist.repop and puts "...reset district #{dist.name}"}
