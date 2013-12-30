#!/usr/bin/oo-ruby
# Trivial listener that just prints the routing info messages as they come.
require 'stomp'
# change your connection info to match activemq configuration.
c = Stomp::Client.new("routinginfo", "routinginfopasswd", "localhost", 61613, true)
c.subscribe('/topic/routinginfo') { |msg| puts msg.body }
c.join # listens forever... use ctrl-C to exit
