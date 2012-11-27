#!/bin/bash
# This script configures a host system with OpenShift components.
# It may be used either as a RHEL6 kickstart script, or the %post section may be
# extracted and run directly to install on top of an installed RHEL6 image.
# When running the %post outside kickstart, a reboot is required afterward.

# SPECIFYING PARAMETERS
#
# If you supply no parameters, all components are installed on one host with default configuration,
# which should give you a running demo.
#
# For a kickstart, you can supply further kernel parameters (in addition to the ks=location itself).
#  e.g. virt-install ... -x "ks=http://.../openshift.ks domain=example.com"
#
# As a bash script, just add the parameters as bash variables at the top of the script (or environment variables).
# Kickstart parameters are mapped to uppercase bash variables prepended with CONF_
# so for example, "domain=example.com" as a kickstart parameter would be "CONF_DOMAIN=example.com" for the script.

# PARAMETER DESCRIPTIONS

# install_components / CONF_INSTALL_COMPONENTS
#   Comma-separated selections from the following:
#     broker - installs the broker webapp and tools
#     named - installs a BIND DNS server
#     activemq - installs the messaging bus
#     datastore - installs the MongoDB datastore
#     node - installs node functionality
#   Default: all.
#   Only the specified components are installed and configured.
#   E.g. install_components=broker,datastore only installs the broker and DB,
#   and assumes you have use other hosts for messaging and DNS.
#
# Example kickstart parameter:
#  install_components="node,broker,named,activemq,datastore"
# Example script variable:
#  CONF_INSTALL_COMPONENTS="node,broker,named,activemq,datastore"

# repos_base / CONF_REPOS_BASE
#   Default: https://mirror.openshift.com/pub/origin-server/nightly/enterprise/<latest>
#   The base URL for the OpenShift repositories used in the post-install.

# domain / CONF_DOMAIN
#   Default: example.com
#   The network domain under which apps and hosts will be placed.

# broker_hostname / CONF_BROKER_HOSTNAME
# node_hostname / CONF_NODE_HOSTNAME
# named_hostname / CONF_NAMED_HOSTNAME
# activemq_hostname / CONF_ACTIVEMQ_HOSTNAME
# datastore_hostname / CONF_DATASTORE_HOSTNAME
#   Default: the root plus the domain, e.g. broker.example.com - except named=ns1.example.com
#   These supply the FQDN of the hosts containing these components. Used for configuring the
#   host's name at install, and also for configuring the broker application to reach the
#   services needed.
#
#   IMPORTANT NOTE: if installing a nameserver, the script will create DNS entries for the
#   hostnames of the other components being installed on this host as well. If you are using
#   a nameserver set up separately, you are responsible for all necessary DNS entries.


# named_ip_addr / CONF_NAMED_IP_ADDR
#   Default: current IP if installing named, otherwise broker_ip_addr
#   This is used by every host to configure its primary nameserver.

# broker_ip_addr / CONF_BROKER_IP_ADDR
#   Default: the current IP (at install)
#   This is used for the node to record its broker.
#   Also is the default for the nameserver IP if none is given.

# node_ip_addr / CONF_NODE_IP_ADDR
#   Default: the current IP (at install)
#   This is used for the node to give a public IP, if different from the one on its NIC.
#   You aren't likely to need to specify this.

# Passwords used to secure various services. You are advised to specify only alphanumeric
# values in this script as others may cause syntax errors depending on context. If
# non-alphanumeric values are required, update them separately after installation.
#
# activemq_admin_password / CONF_ACTIVEMQ_ADMIN_PASSWORD
#   Default: randomized
#   This is the admin password for the ActiveMQ admin console, which is not needed
#   by OpenShift but might be useful in troubleshooting.
#
# mcollective_user / CONF_MCOLLECTIVE_USER
# mcollective_password / CONF_MCOLLECTIVE_PASSWORD
#   Default: mcollective/marionette
#   This is the user and password shared between broker and node for communicating over
#   the mcollective topic channels in ActiveMQ. Must be the same on all broker and node hosts.
#
# mongodb_user / CONF_MONGODB_USER
# mongodb_password / CONF_MONGODB_PASSWORD
# mongodb_name / CONF_MONGODB_NAME
#   Default: openshift:mongopass@openshift_broker
#   This user:password is created for connecting to the MongoDB datastore named $mongodb_name.
#   The broker application's MongoDB plugin is also configured with these values.
#
# openshift_user1 / CONF_OPENSHIFT_USER1
# openshift_password1 / CONF_OPENSHIFT_PASSWORD1
#   Default: demo/changeme
#   This user and password are entered in the /etc/openshift/htpasswd file as a demo/test user.
#   You will likely want to remove it after installation (or just use a different auth method).

# IMPORTANT NOTES - DEPENDENCIES
#
# In order for the %post section to succeed, it must have a way of installing from RHEL 6.
# The post section cannot access the method that was used in the base install.
# So, you must modify this script, either to subscribe to RHEL during the base install,
# or to ensure that the configure_rhel_repo function below subscribes to RHEL
# or configures RHEL yum repos.
#
# The JBoss cartridges similarly require packages from the JBoss entitlements, so you must subscribe
# to the corresponding channels during the base install or modify the
# configure_jbossews_subscription or configure_jbosseap_subscription functions to do so.
#
# The OpenShift repository steps below refer to public beta yum repositories. For a supported
# production product, comment these out and use your OpenShift Enterprise subscription instead.
#
# DO NOT install with third-party (non-RHEL) repos enabled (e.g. EPEL). You may install different
# package versions than OpenShift expects and be in for a long troubleshooting session.
# Also avoid pre-installing third-party software like Puppet for the same reason.
#
# OTHER IMPORTANT NOTES
#
# You will almost certainly want to change the root password or authorized keys (or both) that are
# specified in the script, and/or set up another user/group with sudo access so that you can access
# the system after installation.
#
# If you install a broker, the rhc client is installed as well, for convenient local testing.
# Also, a test user "demo" with password "changeme" is created.
#
# If you want to use the broker from a client outside the installation, then of course that client
# must be using a DNS server that knows about (or is) the DNS server for the installation.
# Otherwise you will have DNS failures when creating the app and be unable to reach it in a browser.
#

# MANUAL TASKS
#
# This script attempts to automate as many tasks as it reasonably can. Unfortunately, it is
# constrained to setting up only a single host at a time. In an assumed multi-host setup,
# you will need to do the following after the script has completed.
#
# 1. Set up DNS entries for hosts
# If you installed BIND with the script, then any other components installed with the script
# on the same host received DNS entries. Other hosts must all be defined manually, including
# at least your node hosts. oo-register-dns may prove useful for this.
#
# 2. Copy public key to enable moving gears
# The broker rsync public key needs to go on nodes, but there is no good way
# to script that generically. Nodes should not have password-less access
# to brokers to copy the .pub key, so this must be performed manually on each node host:
#   [root@node] # scp root@broker:/etc/openshift/rsync_id_rsa.pub /root/.ssh/
#   (the above step will ask for the root password of the broker machine)
#   # cat /root/.ssh/rsync_id_rsa.pub >> /root/.ssh/authorized_keys
#   # rm /root/.ssh/rsync_id_rsa.pub
# If you skip this, each gear move will require typing root passwords for each of the
# node hosts involved.




########################################################################

# Synchronize the system clock to the NTP servers and then synchronize
# hardware clock with that.
synchronize_clock()
{
  # Synchronize the system clock using NTP.
  ntpdate clock.redhat.com

  # Synchronize the hardware clock to the system clock.
  hwclock --systohc
}


# Install SSH keys.  We hardcode a key used for internal OpenShift
# development, but the hardcoded key can be replaced with another or
# with a wget command to download a key from elsewhere.
install_ssh_keys()
{
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  cat >> /root/.ssh/authorized_keys << KEYS
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDkMc2jArUbWICi0071HXrt5uofQam11duqo5KEDWUZGtHuMTzuoZ0XEtzpqoRSidya9HjbJ5A4qUJBrvLZ07l0OIjENQ0Kvz83alVGFrEzVVUSZyiy6+yM9Ksaa/XAYUwCibfaFFqS9aVpVdY0qwaKrxX1ycTuYgNAw3WUvkHagdG54/79M8BUkat4uNiot0bKg6VLSI1QzNYV6cMJeOzz7WzHrJhbPrgXNKmgnAwIKQOkbATYB+YmDyHpA4m/O020dWDk9vWFmlxHLZqddCVGAXFyQnXoFTszFP4wTVOu1q2MSjtPexujYjTbBBxraKw9vrkE25YZJHvbZKMsNm2b libra_onprem
KEYS
}


configure_rhel_repo()
{
  # In order for the %post section to succeed, it must have a way of installing from RHEL.
  # The post section cannot access the method that was used in the base install.
  # So, you must subscribe to RHEL or configure RHEL repos here.

  ## configure RHEL subscription or repos here
  cat <<EOF > /etc/yum.repos.d/rhel.repo
[rhel63]
name=rhel63
baseurl=http://cdn-internal.rcm-test.redhat.com/content/dist/rhel/server/6/6Server/x86_64/os/
enabled=1
gpgcheck=0

EOF
  : # no-op so that this function definition is valid.
}

configure_client_tools_repo()
{
  # Enable repo with the puddle for broker packages.
  cat > /etc/yum.repos.d/openshift-client.repo <<YUM
[openshift_client]
name=OpenShift Client
baseurl=${repos_base}/Client/x86_64/os/
enabled=1
gpgcheck=0
sslverify=false
sslverify=false

YUM
}

configure_broker_repo()
{
  # Enable repo with the puddle for broker packages.
  cat > /etc/yum.repos.d/openshift-infrastructure.repo <<YUM
[openshift_infrastructure]
name=OpenShift Infrastructure
baseurl=${repos_base}/Infrastructure/x86_64/os/
enabled=1
gpgcheck=0
sslverify=false
sslverify=false

YUM
}

configure_node_repo()
{
  # Enable repo with the puddle for node packages.
  cat > /etc/yum.repos.d/openshift-node.repo <<YUM
[openshift_node]
name=OpenShift Node
baseurl=${repos_base}/Node/x86_64/os/
enabled=1
gpgcheck=0
sslverify=false
sslverify=false

YUM
}

configure_jbosseap_cartridge_repo()
{
  # Enable repo with the puddle for the JBossEAP cartridge package.
  cat > /etc/yum.repos.d/openshift-jboss.repo <<YUM
[openshift_jbosseap]
name=OpenShift JBossEAP
baseurl=${repos_base}/JBoss_EAP6_Cartridge/x86_64/os/
enabled=1
gpgcheck=0
sslverify=false
sslverify=false

YUM
}

configure_jbosseap_subscription()
{
  # The JBossEAP cartridge depends on Red Hat's JBoss packages, so you must
  # subscribe to the appropriate channel here.

  ## configure JBossEAP subscription
  cat <<EOF > /etc/yum.repos.d/jbosseap.repo
[jbosseap]
name=jbosseap
baseurl=http://cdn-internal.rcm-test.redhat.com/content/dist/rhel/server/6/6Server/x86_64/jbeap/6/os/
enabled=1
gpgcheck=0

EOF
  : # no-op so that this function definition is valid.
}

configure_jbossews_subscription()
{
  # The JBossEWS cartridge depends on Red Hat's JBoss packages, so you must
  # subscribe to the appropriate channel here.

  ## configure JBossEWS subscription
  cat <<EOF > /etc/yum.repos.d/jbossews.repo
[jbossews]
name=jbossews
baseurl=http://cdn-internal.rcm-test.redhat.com/content/dist/rhel/server/6/6Server/x86_64/jbews/1/os/
enabled=1
gpgcheck=0

EOF
  : # no-op so that this function definition is valid.
}

# Install the client tools.
install_rhc_pkg()
{
  yum install -y rhc
}

# Install broker-specific packages.
install_broker_pkgs()
{
  # Kickstart doesn't handle line continuations.
  pkgs="openshift-origin-broker"
  pkgs="$pkgs openshift-origin-broker-util"
  pkgs="$pkgs rubygem-openshift-origin-msg-broker-mcollective"
  pkgs="$pkgs rubygem-openshift-origin-auth-remote-user"
  pkgs="$pkgs rubygem-openshift-origin-dns-bind"
  pkgs="$pkgs openshift-console"

  yum install -y $pkgs
}

# Install node-specific packages.
install_node_pkgs()
{
  # Kickstart doesn't handle line continuations.
  pkgs="rubygem-openshift-origin-node rubygem-passenger-native"
  pkgs="$pkgs openshift-origin-port-proxy"
  pkgs="$pkgs openshift-origin-node-util"
  # We use semanage in this kickstart script, so we need to install
  # policycoreutils-python.
  pkgs="$pkgs policycoreutils-python"

  yum install -y $pkgs
}

# Install any cartridges developers may want.
install_cartridges()
{
  # Following are cartridge rpms that one may want to install here:

  # Embedded cron support. This is required on node hosts.
  carts="openshift-origin-cartridge-cron-1.4"

  # diy app.
  carts="$carts openshift-origin-cartridge-diy-0.1"

  # haproxy-1.4 support.
  carts="$carts openshift-origin-cartridge-haproxy-1.4"

  # JBossEWS1.0 support.
  # Note: Be sure to subscribe to the JBossEWS entitlements during the
  # base install or in configure_jbossews_subscription.
  #carts="$carts openshift-origin-cartridge-jbossews-1.0"

  # JBossEAP6.0 support.
  # Note: Be sure to subscribe to the JBossEAP entitlements during the
  # base install or in configure_jbosseap_subscription.
  #carts="$carts openshift-origin-cartridge-jbosseap-6.0"

  # Jenkins server for continuous integration.
  carts="$carts openshift-origin-cartridge-jenkins-1.4"

  # Embedded jenkins client.
  carts="$carts openshift-origin-cartridge-jenkins-client-1.4"

  # Embedded MySQL.
  carts="$carts openshift-origin-cartridge-mysql-5.1"

  # mod_perl support.
  carts="$carts openshift-origin-cartridge-perl-5.10"

  # PHP 5.3 support.
  carts="$carts openshift-origin-cartridge-php-5.3"

  # Embedded PostgreSQL.
  carts="$carts openshift-origin-cartridge-postgresql-8.4"

  # Python 2.6 support.
  carts="$carts openshift-origin-cartridge-python-2.6"

  # Ruby Rack support running on Phusion Passenger (Ruby 1.8).
  carts="$carts openshift-origin-cartridge-ruby-1.8"

  # Ruby Rack support running on Phusion Passenger (Ruby 1.9).
  carts="$carts openshift-origin-cartridge-ruby-1.9-scl"

  # When dependencies are missing, e.g. JBoss subscriptions,
  # still install as much as possible.
  carts="$carts --skip-broken"

  yum install -y $carts
}

# Fix up SELinux policy on the broker.
configure_selinux_policy_on_broker()
{
  # We combine these setsebool commands into a single semanage command
  # because separate commands take a long time to run.
  (
    # Allow the console application to access executable and writable memory
    echo boolean -m --on httpd_execmem

    # Allow the broker to write files in the http file context.
    echo boolean -m --on httpd_unified

    # Allow the broker to access the network.
    echo boolean -m --on httpd_can_network_connect
    echo boolean -m --on httpd_can_network_relay

    # Enable some passenger-related permissions.
    #
    # The name may change at some future point, at which point we will
    # need to delete the httpd_run_stickshift line below and enable the
    # httpd_run_openshift line.
    echo boolean -m --on httpd_run_stickshift
    #echo boolean -m --on httpd_run_openshift

    # Allow the broker to communicate with the named service.
    echo boolean -m --on allow_ypbind
  ) | semanage -i -

  fixfiles -R rubygem-passenger restore
  fixfiles -R mod_passenger restore

  restorecon -rv /var/run
  restorecon -rv /usr/share/rubygems/gems/passenger-* 
}

# Fix up SELinux policy on the node.
configure_selinux_policy_on_node()
{
  # We combine these setsebool commands into a single semanage command
  # because separate commands take a long time to run.
  (
    # Allow the node to write files in the http file context.
    echo boolean -m --on httpd_unified

    # Allow the node to access the network.
    echo boolean -m --on httpd_can_network_connect
    echo boolean -m --on httpd_can_network_relay

    # Allow httpd on the node to read gear data.
    #
    # The name may change at some future point, at which point we will
    # need to delete the httpd_run_stickshift line below and enable the
    # httpd_run_openshift line.
    echo boolean -m --on httpd_run_stickshift
    #echo boolean -m --on httpd_run_openshift
    echo boolean -m --on httpd_read_user_content
    echo boolean -m --on httpd_enable_homedirs

    # Enable polyinstantiation for gear data.
    echo boolean -m --on allow_polyinstantiation
  ) | semanage -i -

  fixfiles -R rubygem-passenger restore
  fixfiles -R mod_passenger restore

  restorecon -rv /var/run
  restorecon -rv /usr/share/rubygems/gems/passenger-* 
  restorecon -rv /usr/sbin/mcollectived /var/log/mcollective.log /var/run/mcollectived.pid
  restorecon -rv /var/lib/openshift /etc/openshift/node.conf /etc/httpd/conf.d/openshift
}

configure_pam_on_node()
{
  sed -i -e 's|pam_selinux|pam_openshift|g' /etc/pam.d/sshd

  for f in "runuser" "runuser-l" "sshd" "su" "system-auth-ac"
  do
    t="/etc/pam.d/$f"
    if ! grep -q "pam_namespace.so" "$t"
    then
      echo -e "session\t\trequired\tpam_namespace.so no_unmount_on_close" >> "$t"
    fi
  done
}

configure_cgroups_on_node()
{
  cp -vf /usr/share/doc/*/cgconfig.conf /etc/cgconfig.conf
  restorecon -rv /etc/cgconfig.conf
  mkdir -p /cgroup
  restorecon -rv /cgroup
  chkconfig cgconfig on
  chkconfig cgred on
  chkconfig openshift-cgroups on
}

configure_quotas_on_node()
{
  # Get the mountpoint for /var/lib/openshift (should be /).
  geardata_mnt=$(df -P /var/lib/openshift 2>/dev/null | tail -n 1 | awk '{ print $6 }')

  if ! [ x"$geardata_mnt" != x ]
  then
    echo 'Could not enable quotas for gear data: unable to determine mountpoint.'
  else
    # Enable user quotas for the device housing /var/lib/openshift.
    sed -i -e "/^[^[:blank:]]\\+[[:blank:]]\\+${geardata_mnt////\/}/{/usrquota/! s/[[:blank:]]\\+/,usrquota&/4;}" /etc/fstab

    # Remount to get quotas enabled immediately.
    mount -o remount "${geardata_mnt}"

    # Generate user quota info for the mount point.
    quotacheck -cmug "${geardata_mnt}"
  fi
}

# Turn some sysctl knobs.
configure_sysctl_on_node()
{
  # Increase kernel semaphores to accomodate many httpds.
  echo "kernel.sem = 250  32000 32  4096" >> /etc/sysctl.conf

  # Move ephemeral port range to accommodate app proxies.
  echo "net.ipv4.ip_local_port_range = 15000 35530" >> /etc/sysctl.conf

  # Increase the connection tracking table size.
  echo "net.netfilter.nf_conntrack_max = 1048576" >> /etc/sysctl.conf

  # Reload sysctl.conf to get the new settings.
  #
  # Note: We could add -e here to ignore errors that are caused by
  # options appearing in sysctl.conf that correspond to kernel modules
  # that are not yet loaded.  On the other hand, adding -e might cause
  # us to miss some important error messages.
  sysctl -p /etc/sysctl.conf
}


configure_sshd_on_node()
{
  # Configure sshd to pass the GIT_SSH environment variable through.
  echo 'AcceptEnv GIT_SSH' >> /etc/ssh/sshd_config

  # Up the limits on the number of connections to a given node.
  perl -p -i -e "s/^#MaxSessions .*$/MaxSessions 40/" /etc/ssh/sshd_config
  perl -p -i -e "s/^#MaxStartups .*$/MaxStartups 40/" /etc/ssh/sshd_config
}

# Configure MongoDB datastore.
configure_datastore()
{
  # Install MongoDB.
  yum install -y mongodb-server

  # Require authentication.
  perl -p -i -e "s/^#auth = .*$/auth = true/" /etc/mongodb.conf

  # Use a smaller default size for databases.
  if [ "x`fgrep smallfiles=true /etc/mongodb.conf`x" != "xsmallfiles=truex" ]
  then
    echo 'smallfiles=true' >> /etc/mongodb.conf
  fi

  # Iff mongod is running on a separate host from the broker, open up
  # the firewall to allow the broker host to connect.
  if broker
  then
    echo 'The broker and data store are on the same host.'
    echo 'Skipping firewall and mongod configuration;'
    echo 'mongod will only be accessible over localhost).'
  else
    echo 'The broker and data store are on separate hosts.'

    echo 'Configuring the firewall to allow connections to mongod...'
    lokkit --nostart --port=27017:tcp

    echo 'Configuring mongod to listen on external interfaces...'
    perl -p -i -e "s/^bind_ip = .*$/bind_ip = 0.0.0.0/" /etc/mongodb.conf
  fi

  # Configure mongod to start on boot.
  chkconfig mongod on

  # Start mongod so we can perform some administration now.
  service mongod start
}


# Open up services required on the node for apps and developers.
configure_port_proxy()
{
  lokkit --nostart --port=35531-65535:tcp

  chkconfig openshift-port-proxy on
}

configure_gears()
{
  # Make sure that gears are restarted on reboot.
  chkconfig openshift-gears on
}


# Enable services to start on boot for the node.
enable_services_on_node()
{
  # We use --nostart below because activating the configuration here will
  # produce errors.  Anyway, we only need the configuration activated
  # after Anaconda reboots, so --nostart makes sense in any case.

  lokkit --nostart --service=ssh
  lokkit --nostart --service=https
  lokkit --nostart --service=http

  chkconfig httpd on
  chkconfig network on
  chkconfig sshd on
  chkconfig oddjobd on
}


# Enable services to start on boot for the broker.
enable_services_on_broker()
{
  # We use --nostart below because activating the configuration here will
  # produce errors.  Anyway, we only need the configuration activated
  # after Anaconda reboots, so --nostart makes sense in any case.

  lokkit --nostart --service=ssh
  lokkit --nostart --service=https
  lokkit --nostart --service=http

  chkconfig httpd on
  chkconfig network on
  is_false "$CONF_NO_NTP" && chkconfig ntpd on
  chkconfig sshd on

  # The broker httpd proxy ServerName should be set in order to avoid conflicting
  # with the default ssl.conf
  sed -i -e "s/ServerName .*$/ServerName ${hostname}/" /etc/httpd/conf.d/000000_openshift_origin_broker_proxy.conf
}


# Configure mcollective on the broker to use qpid.
configure_mcollective_for_qpid_on_broker()
{
  yum install -y mcollective-client

  cat <<EOF > /etc/mcollective/client.cfg
topicprefix = /topic/
main_collective = mcollective
collectives = mcollective
libdir = /usr/libexec/mcollective
loglevel = debug
logfile = /var/log/mcollective-client.log

# Plugins
securityprovider = psk
plugin.psk = unset
connector = qpid
plugin.qpid.host = ${broker_hostname}
plugin.qpid.secure = false
plugin.qpid.timeout = 5

# Facts
factsource = yaml
plugin.yaml = /etc/mcollective/facts.yaml
EOF

chown root:apache /var/log/mcollective-client.log
}


# Configure mcollective on the broker to use qpid.
configure_mcollective_for_qpid_on_node()
{
  yum install -y mcollective openshift-origin-msg-node-mcollective

  cat <<EOF > /etc/mcollective/server.cfg
topicprefix = /topic/
main_collective = mcollective
collectives = mcollective
libdir = /usr/libexec/mcollective
logfile = /var/log/mcollective.log
loglevel = debug
daemonize = 1
direct_addressing = n

# Plugins
securityprovider = psk
plugin.psk = unset
connector = qpid
plugin.qpid.host = ${broker_hostname}
plugin.qpid.secure = false
plugin.qpid.timeout = 5

# Facts
factsource = yaml
plugin.yaml = /etc/mcollective/facts.yaml
EOF

  chkconfig mcollective on
}


# Configure mcollective on the broker to use ActiveMQ.
configure_mcollective_for_activemq_on_broker()
{
  yum install -y mcollective-client

  cat <<EOF > /etc/mcollective/client.cfg
topicprefix = /topic/
main_collective = mcollective
collectives = mcollective
libdir = /usr/libexec/mcollective
logfile = /var/log/mcollective-client.log
loglevel = debug

# Plugins
securityprovider=psk
plugin.psk=unset

connector = stomp
plugin.stomp.host = ${activemq_hostname}
plugin.stomp.port = 61613
plugin.stomp.user = ${mcollective_user}
plugin.stomp.password = ${mcollective_password}
EOF

chown root:apache /var/log/mcollective-client.log
}


# Configure mcollective on the node to use ActiveMQ.
configure_mcollective_for_activemq_on_node()
{
  yum install -y mcollective openshift-origin-msg-node-mcollective

  cat <<EOF > /etc/mcollective/server.cfg
topicprefix = /topic/
main_collective = mcollective
collectives = mcollective
libdir = /usr/libexec/mcollective
logfile = /var/log/mcollective.log
loglevel = debug
daemonize = 1
direct_addressing = n
registerinterval = 30

# Plugins
securityprovider = psk
plugin.psk = unset

connector = stomp
plugin.stomp.host = ${activemq_hostname}
plugin.stomp.port = 61613
plugin.stomp.user = ${mcollective_user}
plugin.stomp.password = ${mcollective_password}

# Facts
factsource = yaml
plugin.yaml = /etc/mcollective/facts.yaml
EOF

  chkconfig mcollective on
}


# Configure ActiveMQ.
configure_activemq()
{
  # Install the service.
  yum install -y activemq

  cat <<EOF > /etc/activemq/activemq.xml
<!--
    Licensed to the Apache Software Foundation (ASF) under one or more
    contributor license agreements.  See the NOTICE file distributed with
    this work for additional information regarding copyright ownership.
    The ASF licenses this file to You under the Apache License, Version 2.0
    (the "License"); you may not use this file except in compliance with
    the License.  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
-->
<beans
  xmlns="http://www.springframework.org/schema/beans"
  xmlns:amq="http://activemq.apache.org/schema/core"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
  xsi:schemaLocation="http://www.springframework.org/schema/beans http://www.springframework.org/schema/beans/spring-beans-2.0.xsd
  http://activemq.apache.org/schema/core http://activemq.apache.org/schema/core/activemq-core.xsd">

    <!-- Allows us to use system properties as variables in this configuration file -->
    <bean class="org.springframework.beans.factory.config.PropertyPlaceholderConfigurer">
        <property name="locations">
            <value>file:\${activemq.conf}/credentials.properties</value>
        </property>
    </bean>

    <!--
        The <broker> element is used to configure the ActiveMQ broker.
    -->
    <broker xmlns="http://activemq.apache.org/schema/core" brokerName="${activemq_hostname}" dataDirectory="\${activemq.data}">

        <!--
            For better performances use VM cursor and small memory limit.
            For more information, see:

            http://activemq.apache.org/message-cursors.html

            Also, if your producer is "hanging", it's probably due to producer flow control.
            For more information, see:
            http://activemq.apache.org/producer-flow-control.html
        -->

        <destinationPolicy>
            <policyMap>
              <policyEntries>
                <policyEntry topic=">" producerFlowControl="true" memoryLimit="1mb">
                  <pendingSubscriberPolicy>
                    <vmCursor />
                  </pendingSubscriberPolicy>
                </policyEntry>
                <policyEntry queue=">" producerFlowControl="true" memoryLimit="1mb">
                  <!-- Use VM cursor for better latency
                       For more information, see:

                       http://activemq.apache.org/message-cursors.html

                  <pendingQueuePolicy>
                    <vmQueueCursor/>
                  </pendingQueuePolicy>
                  -->
                </policyEntry>
              </policyEntries>
            </policyMap>
        </destinationPolicy>


        <!--
            The managementContext is used to configure how ActiveMQ is exposed in
            JMX. By default, ActiveMQ uses the MBean server that is started by
            the JVM. For more information, see:

            http://activemq.apache.org/jmx.html
        -->
        <managementContext>
            <managementContext createConnector="false"/>
        </managementContext>

        <!--
            Configure message persistence for the broker. The default persistence
            mechanism is the KahaDB store (identified by the kahaDB tag).
            For more information, see:

            http://activemq.apache.org/persistence.html
        -->
        <persistenceAdapter>
            <kahaDB directory="\${activemq.data}/kahadb"/>
        </persistenceAdapter>

        <!-- add users for mcollective -->

        <plugins>
          <statisticsBrokerPlugin/>
          <simpleAuthenticationPlugin>
             <users>
               <authenticationUser username="${mcollective_user}" password="${mcollective_password}" groups="mcollective,everyone"/>
               <authenticationUser username="admin" password="${activemq_admin_password}" groups="mcollective,admin,everyone"/>
             </users>
          </simpleAuthenticationPlugin>
          <authorizationPlugin>
            <map>
              <authorizationMap>
                <authorizationEntries>
                  <authorizationEntry queue=">" write="admins" read="admins" admin="admins" />
                  <authorizationEntry topic=">" write="admins" read="admins" admin="admins" />
                  <authorizationEntry topic="mcollective.>" write="mcollective" read="mcollective" admin="mcollective" />
                  <authorizationEntry queue="mcollective.>" write="mcollective" read="mcollective" admin="mcollective" />
                  <authorizationEntry topic="ActiveMQ.Advisory.>" read="everyone" write="everyone" admin="everyone"/>
                </authorizationEntries>
              </authorizationMap>
            </map>
          </authorizationPlugin>
        </plugins>

          <!--
            The systemUsage controls the maximum amount of space the broker will
            use before slowing down producers. For more information, see:
            http://activemq.apache.org/producer-flow-control.html
            If using ActiveMQ embedded - the following limits could safely be used:

        <systemUsage>
            <systemUsage>
                <memoryUsage>
                    <memoryUsage limit="20 mb"/>
                </memoryUsage>
                <storeUsage>
                    <storeUsage limit="1 gb"/>
                </storeUsage>
                <tempUsage>
                    <tempUsage limit="100 mb"/>
                </tempUsage>
            </systemUsage>
        </systemUsage>
        -->
          <systemUsage>
            <systemUsage>
                <memoryUsage>
                    <memoryUsage limit="64 mb"/>
                </memoryUsage>
                <storeUsage>
                    <storeUsage limit="100 gb"/>
                </storeUsage>
                <tempUsage>
                    <tempUsage limit="50 gb"/>
                </tempUsage>
            </systemUsage>
        </systemUsage>

        <!--
            The transport connectors expose ActiveMQ over a given protocol to
            clients and other brokers. For more information, see:

            http://activemq.apache.org/configuring-transports.html
        -->
        <transportConnectors>
            <transportConnector name="openwire" uri="tcp://0.0.0.0:61616"/>
            <transportConnector name="stomp" uri="stomp://0.0.0.0:61613"/>
        </transportConnectors>

    </broker>

    <!--
        Enable web consoles, REST and Ajax APIs and demos

        Take a look at \${ACTIVEMQ_HOME}/conf/jetty.xml for more details
    -->
    <import resource="jetty.xml"/>

</beans>
<!-- END SNIPPET: example -->
EOF

  # secure the ActiveMQ console
  sed -i -e '/name="authenticate"/s/false/true/' /etc/activemq/jetty.xml
  sed -i -e '/name="port"/a<property name="host" value="127.0.0.1" />' /etc/activemq/jetty.xml
  sed -i -e "/admin:/s/admin,/${activemq_admin_password},/" /etc/activemq/jetty-realm.properties


  # Allow connections to ActiveMQ.
  lokkit --nostart --port=61613:tcp

  # Configure ActiveMQ to start on boot.
  chkconfig activemq on
}


# Configure qpid. Deprecated for ActiveMQ.
configure_qpid()
{
  if [[ "x`fgrep auth= /etc/qpidd.conf`" == xauth* ]]
  then
    sed -i -e 's/auth=yes/auth=no/' /etc/qpidd.conf
  else
    echo "auth=no" >> /etc/qpidd.conf
  fi

  # Allow connections to qpidd.
  lokkit --nostart --port=5672:tcp

  # Configure qpidd to start on boot.
  chkconfig qpidd on
}


# Configure BIND.
configure_named()
{
  yum install -y bind bind-utils

  # $keyfile will contain a new DNSSEC key for our domain.
  keyfile=/var/named/${domain}.key

  if [ "x$bind_key" = x ]
  then
    # Generate the new key for the domain.
    pushd /var/named
    rm -f /var/named/K${domain}*
    dnssec-keygen -a HMAC-MD5 -b 512 -n USER -r /dev/urandom ${domain}
    bind_key="$(grep Key: K${domain}*.private | cut -d ' ' -f 2)"
    popd
  fi

  # Ensure we have a key for the broker to communicate with BIND.
  rndc-confgen -a -r /dev/urandom
  restorecon /etc/rndc.* /etc/named.*
  chown root:named /etc/rndc.key
  chmod 640 /etc/rndc.key

  # Set up DNS forwarding.
  cat <<EOF > /var/named/forwarders.conf
forwarders { ${nameservers} } ;
EOF
  restorecon /var/named/forwarders.conf
  chmod 644 /var/named/forwarders.conf

  # Install the configuration file for the OpenShift Enterprise domain
  # name.
  rm -rf /var/named/dynamic
  mkdir -p /var/named/dynamic


  # Create the initial BIND database.
  nsdb=/var/named/dynamic/${domain}.db
  cat <<EOF > $nsdb
\$ORIGIN .
\$TTL 1	; 1 seconds (for testing only)
${domain}		IN SOA	${named_hostname}. hostmaster.${domain}. (
				2011112904 ; serial
				60         ; refresh (1 minute)
				15         ; retry (15 seconds)
				1800       ; expire (30 minutes)
				10         ; minimum (10 seconds)
				)
			NS	${named_hostname}.
			MX	10 mail.${domain}.
\$ORIGIN ${domain}.
${named_hostname%.${domain}}			A	${named_ip_addr}
EOF

  # Add A records any other components that are being installed locally.
  broker && echo "${broker_hostname%.${domain}}			A	${broker_ip_addr}" >> $nsdb
  node && echo "${node_hostname%.${domain}}			A	${node_ip_addr}${nl}" >> $nsdb
  activemq && echo "${activemq_hostname%.${domain}}			A	${cur_ip_addr}${nl}" >> $nsdb
  datastore && echo "${datastore_hostname%.${domain}}			A	${cur_ip_addr}${nl}" >> $nsdb
  echo >> $nsdb

  # Install the key for the OpenShift Enterprise domain.
  cat <<EOF > /var/named/${domain}.key
key ${domain} {
  algorithm HMAC-MD5;
  secret "${bind_key}";
};
EOF

  chown named:named -R /var/named
  restorecon -rv /var/named

  # Replace named.conf.
  cat <<EOF > /etc/named.conf
// named.conf
//
// Provided by Red Hat bind package to configure the ISC BIND named(8) DNS
// server as a caching only nameserver (as a localhost DNS resolver only).
//
// See /usr/share/doc/bind*/sample/ for example named configuration files.
//

options {
	listen-on port 53 { any; };
	directory 	"/var/named";
	dump-file 	"/var/named/data/cache_dump.db";
        statistics-file "/var/named/data/named_stats.txt";
        memstatistics-file "/var/named/data/named_mem_stats.txt";
	allow-query     { any; };
	recursion yes;

	/* Path to ISC DLV key */
	bindkeys-file "/etc/named.iscdlv.key";

	// set forwarding to the next nearest server (from DHCP response
	forward only;
        include "forwarders.conf";
};

logging {
        channel default_debug {
                file "data/named.run";
                severity dynamic;
        };
};

// use the default rndc key
include "/etc/rndc.key";
 
controls {
	inet 127.0.0.1 port 953
	allow { 127.0.0.1; } keys { "rndc-key"; };
};

include "/etc/named.rfc1912.zones";

include "${domain}.key";

zone "${domain}" IN {
	type master;
	file "dynamic/${domain}.db";
	allow-update { key ${domain} ; } ;
};
EOF
  chown root:named /etc/named.conf
  chcon system_u:object_r:named_conf_t:s0 -v /etc/named.conf

  # Configure named to start on boot.
  lokkit --nostart --service=dns
  chkconfig named on

  # Start named so we can perform some updates immediately.
  service named start
}


# Make resolv.conf point to our named service, which will resolve the
# host names used in this installation of OpenShift.  Our named service
# will forward other requests to some other DNS servers.
update_resolv_conf()
{
  # Update resolv.conf to use our named.
  #
  # We will keep any existing entries so that we have fallbacks that
  # will resolve public addresses even when our private named is
  # nonfunctional.  However, our private named must appear first in
  # order for hostnames private to our OpenShift PaaS to resolve.
  sed -i -e "1i# The named we install for our OpenShift PaaS must appear first.\\nnameserver ${named_ip_addr}\\n" /etc/resolv.conf
}


# Update the controller configuration.
configure_controller()
{
  if [ "x$broker_auth_salt" = "x" ]
  then
    echo "Warning: broker authentication salt is empty!"
  fi

  # Configure the broker with the correct hostname, and use random salt
  # to the data store (the host running MongoDB).
  sed -i -e "s/^CLOUD_DOMAIN=.*$/CLOUD_DOMAIN=${domain}/;
             s/^AUTH_SALT=.*/AUTH_SALT=\"${broker_auth_salt//\//\\/}\"/" \
      /etc/openshift/broker.conf

  if ! datastore
  then
    #mongo not installed locally, so point to given hostname
    sed -i -e "s/^MONGO_HOST_PORT=.*$/MONGO_HOST_PORT=\"${datastore_hostname}:27017\"/" /etc/openshift/broker.conf
  fi

  # configure MongoDB access
  sed -i -e "s/MONGO_PASSWORD=.*$/MONGO_PASSWORD=\"${mongodb_password}\"/
            s/MONGO_USER=.*$/MONGO_USER=\"${mongodb_user}\"/
            s/MONGO_DB=.*$/MONGO_DB=\"${mongodb_name}\"/" \
      /etc/openshift/broker.conf

  # Configure the broker service to start on boot.
  chkconfig openshift-broker on
  chkconfig openshift-console on
}

# Set the administrative password for the database.
configure_mongo_password()
{
  # The init script lies to us as of version 2.0.2-1.el6_3: The start and
  # restart actions return before the daemon is ready to accept
  # connections (it appears to take time to initialize the journal).  Thus
  # we need the following to wait until the daemon is really ready.
  echo "Waiting for MongoDB to start ($(date +%H:%M:%S))..."
  while :
  do
    echo exit | mongo && break
    sleep 5
  done
  echo "MongoDB is ready! ($(date +%H:%M:%S))"

  mongo $mongodb_name --eval "db.addUser(\"${mongodb_user}\", \"${mongodb_password}\")"
}

# Configure the broker to use the remote-user authentication plugin.
configure_remote_user_auth_plugin()
{
  cp /etc/openshift/plugins.d/openshift-origin-auth-remote-user.conf{.example,}
}

# Configure the broker to use the MongoDB-based authentication plugin.
#
# NB: It is assumed that configure_datastore has previously been run on
# this host to install and configure MongoDB.
configure_mongo_auth_plugin()
{
  cp /etc/openshift/plugins.d/openshift-origin-auth-mongo.conf{.example,}

  if ! datastore
  then
    # MongoDB is running on a remote host, so we must modify the
    # plug-in configuration to point it to that host.
    sed -i -e "s/^MONGO_HOST_PORT=.*$/MONGO_HOST_PORT=\"${datastore_hostname}:27017\"/" /etc/openshift/plugins.d/openshift-origin-auth-mongo.conf
  fi

  # We must specify the --host, --username, and --password options iff the
  # datastore is being installed on the current host.
  if datastore
  then
    mongo_opts=""
  else
    mongo_opts="--host ${datastore_hostname} --username openshift --password mooo"
  fi

  # The init script is broken as of version 2.0.2-1.el6_3: The start and
  # restart actions return before the daemon is ready to accept
  # connections (it appears to take time to initialize the journal).  Thus
  # we need the following hack to wait until the daemon is ready.
  echo "Waiting for MongoDB to start ($(date +%H:%M:%S))..."
  while :
  do
    echo exit | mongo $mongo_opts && break
    sleep 5
  done
  echo "MongoDB is ready! ($(date +%H:%M:%S))"

  hashed_password="$(printf 'admin' | md5sum -b | cut -d' ' -f1)"
  hashed_salted_password="$(printf '%s' "$hashed_password$broker_auth_salt" | md5sum | cut -d' ' -f1)"

  # Add user "admin" with password "admin" for oo-register-user.
  mongo $mongodb_name $mongo_opts --eval 'db.auth_user.update({"_id":"admin"}, {"_id":"admin","user":"admin","password":"'"$hashed_salted_password"'"}, true)'
}

configure_messaging_plugin()
{
  cp /etc/openshift/plugins.d/openshift-origin-msg-broker-mcollective.conf{.example,}
}

# Configure the broker to use the BIND DNS plug-in.
configure_dns_plugin()
{
  if [ "x$bind_key" = x ]
  then
    echo 'WARNING: No key has been set for communication with BIND.'
    echo 'You will need to modify the value of BIND_KEYVALUE in'
    echo '/etc/openshift/plugins.d/openshift-origin-dns-bind.conf'
    echo 'after installation.'
  fi

  mkdir -p /etc/openshift/plugins.d
  cat <<EOF > /etc/openshift/plugins.d/openshift-origin-dns-bind.conf
BIND_SERVER="${named_ip_addr}"
BIND_PORT=53
BIND_KEYNAME="${domain}"
BIND_KEYVALUE="${bind_key}"
BIND_ZONE="${domain}"
EOF

  if named
  then
    echo 'Broker and bind are running on the same host - installing custom SELinux policy'
    pushd /usr/share/selinux/packages/rubygem-openshift-origin-dns-bind/ && make -f /usr/share/selinux/devel/Makefile ; popd
    semodule -i /usr/share/selinux/packages/rubygem-openshift-origin-dns-bind/dhcpnamedforward.pp
  fi
}

# Configure httpd for authentication.
configure_httpd_auth()
{
  # Install the Apache configuration file.
  cp /var/www/openshift/broker/httpd/conf.d/openshift-origin-auth-remote-user-basic.conf.sample \
     /var/www/openshift/broker/httpd/conf.d/openshift-origin-auth-remote-user.conf

  cp /var/www/openshift/console/httpd/conf.d/openshift-origin-auth-remote-user-basic.conf.sample \
     /var/www/openshift/console/httpd/conf.d/openshift-origin-auth-remote-user.conf

  # The above configuration file configures Apache to use
  # /etc/openshift/htpasswd for its password file.
  #
  # Here we create a test user:
  htpasswd -bc /etc/openshift/htpasswd "$openshift_user1" "$openshift_password1"
  #
  # Use the following command to add more users:
  #
  #  htpasswd /etc/openshift/htpasswd username

  # TODO: In the future, we will want to edit
  # /etc/openshift/plugins.d/openshift-origin-auth-remote-user.conf to
  # put in a random salt.
}

configure_access_keys_on_broker()
{
  # Generate a broker access key for remote apps (Jenkins) to access the broker.
  openssl genrsa -out /etc/openshift/server_priv.pem 2048
  openssl rsa -in /etc/openshift/server_priv.pem -pubout > /etc/openshift/server_pub.pem

  # Generate a key pair for moving gears between nodes from the broker
  ssh-keygen -t rsa -b 2048 -P "" -f /root/.ssh/rsync_id_rsa
  cp ~/.ssh/rsync_id_rsa* /etc/openshift/
  # the .pub key needs to go on nodes, but there is no good way
  # to script that generically. Nodes should not have password-less access
  # to brokers to copy the .pub key, but this can be performed manually:
  # [root@node] # scp root@broker:/etc/openshift/rsync_id_rsa.pub /root/.ssh/
  # the above step will ask for the root password of the broker machine
  # # cat /root/.ssh/rsync_id_rsa.pub >> /root/.ssh/authorized_keys
  # # rm /root/.ssh/rsync_id_rsa.pub
}

# Configure IP address and hostname.
configure_network()
{
  # Append some stuff to the DHCP configuration.
  cat <<EOF >> /etc/dhcp/dhclient-eth0.conf

prepend domain-name-servers ${named_ip_addr};
supersede host-name "${hostname}";
supersede domain-name "${domain}";
EOF
}

# Set the hostname
configure_hostname()
{
  sed -i -e "s/HOSTNAME=.*/HOSTNAME=${hostname}/" /etc/sysconfig/network
  hostname "${hostname}"
}

# Set some parameters in the OpenShift node configuration file.
configure_node()
{
  sed -i -e "s/^PUBLIC_IP=.*$/PUBLIC_IP=${node_ip_addr}/;
             s/^CLOUD_DOMAIN=.*$/CLOUD_DOMAIN=${domain}/;
             s/^PUBLIC_HOSTNAME=.*$/PUBLIC_HOSTNAME=${hostname}/;
             s/^BROKER_HOST=.*$/BROKER_HOST=${broker_ip_addr}/" \
      /etc/openshift/node.conf
}

# Run the cronjob installed by openshift-origin-msg-node-mcollective immediately
# to regenerate facts.yaml.
update_openshift_facts_on_node()
{
  /etc/cron.minutely/openshift-facts
}

echo_installation_intentions()
{
  echo "The following components should be installed:"
  for component in $components
  do
    if eval $component
    then
      printf '\t%s.\n' $component
    fi
  done

  echo "Configuring with broker with hostname ${broker_hostname}."
  node && echo "Configuring node with hostname ${node_hostname}."
  echo "Configuring with named with IP address ${named_ip_addr}."
  broker && echo "Configuring with datastore with hostname ${datastore_hostname}."
  echo "Configuring with activemq with hostname ${activemq_hostname}."
}

# Modify console message to show install info
configure_console_msg()
{
  # add the IP to /etc/issue for convenience
  echo "Install-time IP address: ${cur_ip_addr}" >> /etc/issue
  echo_installation_intentions >> /etc/issue
  echo "Check /root/anaconda-post.log to see the %post output." >> /etc/issue
  echo >> /etc/issue
}



########################################################################

#
# Parse the kernel command-line, define variables with the parameters
# specified on it, and define functions broker() and node(), which
# return true or false as appropriate based on whether we are
# configuring the host as a broker or as a node.
#

# Parse /proc/cmdline so that from, e.g., "foo=bar baz" we get
# CONF_FOO=bar and CONF_BAZ=true in the environment.
parse_cmdline()
{
  for word in $(cat /proc/cmdline)
  do
    key="${word%%\=*}"
    case "$word" in
      (*=*) val="${word#*\=}" ;;
      (*) val=true ;;
    esac
    eval "CONF_${key^^}"'="$val"'
  done
}

is_true()
{
  for arg
  do
    [[ x$arg =~ x(1|true) ]] || return 1
  done

  return 0
}

is_false()
{
  for arg
  do
    [[ x$arg =~ x(1|true) ]] || return 0
  done

  return 1
}

# For each component, this function defines a constant function that
# returns either true or false.  For example, there will be a named
# function indicating whether we are currently installing the named
# service.  We can use 'if named; then ...; fi' or just 'named && ...'
# to run the given commands if, and only if, named is being installed
# on this host.
#
# The following functions will be defined:
#
#   activemq
#   broker
#   datastore
#   named
#   node
#
# For each component foo, we also set a $foo_hostname variable with the
# hostname for that logical host.  We use hostnames in configuration
# files wherever possible.  The only places where this is not possible
# is where we are referencing the named service; in such places, we use
# $named_ip_addr, which is also set by this function.  It is possible
# that one host runs multiple services, in which case more than one
# hostname will resolve to the same IP address.
#
# We also set the $domain variable, which is the domain that will be
# used when configuring BIND and assigning hostnames for the various
# hosts in the OpenShift PaaS.
#
# We also set the $repos_base variable with the base URL for the yum
# repositories that will be used to download OpenShift RPMs.  The value
# of this variable can be changed to use a custom repository or puddle.
#
# We also set the $cur_ip_addr variable to the IP address of the host
# running this kickstart script, based on the output of the `ip addr
# show` command.
#
# In addition, the $nameservers variable will be set to
# a semicolon-delimited list of nameservers, suitable for use in
# named.conf, based on the existing contents of /etc/resolv.conf, and
# the $bind_key variable will be set to the value of CONF_BIND_KEY.
#
# The following variables will be defined:
#
#   activemq_hostname
#   bind_key
#   broker_hostname
#   cur_ip_addr
#   domain
#   datastore_hostname
#   named_hostname
#   named_ip_addr
#   nameservers
#   node_hostname
#   repos_base
#
# This function makes use of variables that may be set by parse_cmdline
# based on the content of /proc/cmdline or may be hardcoded by modifying
# this file.  All of these variables are optional; best attempts are
# made at determining reasonable defaults.
#
# The following variables are used:
#
#   CONF_ACTIVEMQ_HOSTNAME
#   CONF_BIND_KEY
#   CONF_BROKER_HOSTNAME
#   CONF_BROKER_IP_ADDR
#   CONF_DATASTORE_HOSTNAME
#   CONF_DOMAIN
#   CONF_INSTALL_COMPONENTS
#   CONF_NAMED_HOSTNAME
#   CONF_NAMED_IP_ADDR
#   CONF_NODE_HOSTNAME
#   CONF_NODE_IP_ADDR
#   CONF_REPOS_BASE
set_defaults()
{
  # Following are the different components that can be installed:
  components='broker node named activemq datastore'

  # By default, each component is _not_ installed.
  for component in $components
  do
    eval "$component() { false; }"
  done

  # But any or all components may be explicity enabled.
  for component in ${CONF_INSTALL_COMPONENTS//,/ }
  do
    eval "$component() { :; }"
  done

  # If nothing is explicitly enabled, enable everything.
  installing_something=0
  for component in $components
  do
    if eval $component
    then
      installing_something=1
      break
    fi
  done
  if [ $installing_something = 0 ]
  then
    for component in $components
    do
      eval "$component() { :; }"
    done
  fi

  # Following are some settings used in subsequent steps.

  # Where to find the OpenShift repositories; just the base part before
  # splitting out into Infrastructure/Node/etc.
  repos_base_default='https://mirror.openshift.com/pub/origin-server/nightly/enterprise/2012-11-15'
repos_base_default=http://buildvm-devops.usersys.redhat.com/puddle/build/OpenShiftEnterprise/Beta/latest
  repos_base="${CONF_REPOS_BASE:-${repos_base_default}}"

  # The domain name for the OpenShift Enterprise installation.
  domain="${CONF_DOMAIN:-example.com}"

  # hostnames to use for the components (could all resolve to same host)
  broker_hostname="${CONF_BROKER_HOSTNAME:-broker.${domain}}"
  node_hostname="${CONF_NODE_HOSTNAME:-node.${domain}}"
  named_hostname="${CONF_NAMED_HOSTNAME:-ns1.${domain}}"
  activemq_hostname="${CONF_ACTIVEMQ_HOSTNAME:-activemq.${domain}}"
  datastore_hostname="${CONF_DATASTORE_HOSTNAME:-datastore.${domain}}"

  # The hostname name for this host.
  # Note: If this host is, e.g., both a broker and a datastore, we want to
  # go with the broker hostname and not the datastore hostname.
  if broker
  then hostname="$broker_hostname"
  elif node
  then hostname="$node_hostname"
  elif named
  then hostname="$named_hostname"
  elif activemq
  then hostname="$activemq_hostname"
  elif datastore
  then hostname="$datastore_hostname"
  fi

  # Grab the IP address set during installation.
  cur_ip_addr="$(/sbin/ip addr show dev eth0 | awk '/inet / { split($2,a,"/"); print a[1]; }')"

  # Unless otherwise specified, the broker is assumed to be the current
  # host.
  broker_ip_addr="${CONF_BROKER_IP_ADDR:-$cur_ip_addr}"

  # Unless otherwise specified, the node is assumed to be the current
  # host.
  node_ip_addr="${CONF_NODE_IP_ADDR:-$cur_ip_addr}"

  # Unless otherwise specified, the named service, data store, and
  # ActiveMQ service are assumed to be the current host if we are
  # installing the component now or the broker host otherwise.
  if named
  then
    named_ip_addr="${CONF_NAMED_IP_ADDR:-$cur_ip_addr}"
  else
    named_ip_addr="${CONF_NAMED_IP_ADDR:-$broker_ip_addr}"
  fi

  # The nameservers to which named on the broker will forward requests.
  # This should be a list of IP addresses with a semicolon after each.
  nameservers="$(awk '/nameserver/ { printf "%s; ", $2 }' /etc/resolv.conf)"

  # Set $bind_key to the value of $CONF_BIND_KEY if the latter is
  # non-empty.
  [ "x$CONF_BIND_KEY" != x ] && bind_key="$CONF_BIND_KEY"

  # Generate a random salt for the broker authentication.
  randomized=$(openssl rand -base64 20)
  broker && broker_auth_salt="${CONF_BROKER_AUTH_SALT:-${randomized}}"

  # Set default passwords
  #
  #   This is the admin password for the ActiveMQ admin console, which is not needed
  #   by OpenShift but might be useful in troubleshooting.
  activemq && activemq_admin_password="${CONF_ACTIVEMQ_ADMIN_PASSWORD:-${randomized//[![:alnum:]]}}"

  #   This is the user and password shared between broker and node for communicating over
  #   the mcollective topic channels in ActiveMQ. Must be the same on all broker and node hosts.
  mcollective_user="${CONF_MCOLLECTIVE_USER:-mcollective}"
  mcollective_password="${CONF_MCOLLECTIVE_PASSWORD:-marionette}"

  #   This is the user and password that are created for connecting to the MongoDB datastore.
  #   The broker application's MongoDB plugin is also configured with these values.
  mongodb_user="${CONF_MONGODB_USER:-openshift}"
  mongodb_password="${CONF_MONGODB_PASSWORD:-mongopass}"
  mongodb_name="${CONF_MONGODB_NAME:-openshift_broker}"

  #   This user and password are entered in the /etc/openshift/htpasswd file as a demo/test user.
  #   You will likely want to remove it after installation (or just use a different auth method).
  broker && openshift_user1="${CONF_OPENSHIFT_USER1:-demo}"
  broker && openshift_password1="${CONF_OPENSHIFT_PASSWORD1:-changeme}"
}


########################################################################

# Note: This function is only needed for kickstart and not if this %post
# section is extracted and executed on a running system.
parse_cmdline

set_defaults

echo_installation_intentions
configure_console_msg

is_false "$CONF_NO_NTP" && synchronize_clock
is_false "$CONF_NO_SSH_KEYS" && install_ssh_keys

configure_rhel_repo
if activemq || broker || datastore
then
  configure_broker_repo
fi
node && configure_node_repo
node && configure_jbosseap_cartridge_repo
node && configure_jbosseap_subscription
node && configure_jbossews_subscription
broker && configure_client_tools_repo

yum update -y

# Note: configure_named must run before configure_controller if we are
# installing both named and broker on the same host.
named && configure_named

update_resolv_conf

configure_network
configure_hostname

datastore && configure_datastore

#broker && configure_qpid
activemq && configure_activemq

#broker && configure_mcollective_for_qpid_on_broker
broker && configure_mcollective_for_activemq_on_broker

#node && configure_mcollective_for_qpid_on_node
node && configure_mcollective_for_activemq_on_node

broker && install_broker_pkgs
node && install_node_pkgs
node && install_cartridges
broker && install_rhc_pkg

broker && enable_services_on_broker
node && enable_services_on_node

node && configure_pam_on_node
node && configure_cgroups_on_node
node && configure_quotas_on_node

broker && configure_selinux_policy_on_broker
node && configure_selinux_policy_on_node

node && configure_sysctl_on_node
node && configure_sshd_on_node

broker && configure_controller
broker && configure_remote_user_auth_plugin
broker && configure_access_keys_on_broker
#broker && configure_mongo_auth_plugin
broker && configure_messaging_plugin
broker && configure_dns_plugin
broker && configure_httpd_auth

datastore && configure_mongo_password

node && configure_port_proxy
node && configure_gears
node && configure_node
node && update_openshift_facts_on_node

