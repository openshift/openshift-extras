#!/bin/bash -x
# -*- mode: bash; sh-basic-offset: 2 -*-
# This script configures a single host with OpenShift components. It may
# be used either as a RHEL6 kickstart script, or the %post section may
# be extracted and run directly to deploy on an installed RHEL6 image.
#
# While this script provides many options and is well-equipped for many
# deployments, it is not comprehensive or flexible enough to fulfill
# every enterprise use case. Production deployments can be expected to
# require significant adaptations and the script is designed to be modular
# for ease of customization.

# Table of contents:
#
# RECENT CHANGES
# SPECIFYING PARAMETERS
# INSTALLATION REPOSITORIES
# OTHER IMPORTANT NOTES
# POST-DEPLOY STEP
# MANUAL TASKS
# PARAMETER DESCRIPTIONS
# - General script options
# - Service users and passwords
# - Parameters for all hosts
# - Brokers
# - DNS service
# - Redundant MongoDB and ActiveMQ
# - Node hosts
# - Parameters for "yum" install method

# RECENT CHANGES - very important when adding to existing deployments.
#
# 1. During the lifetime of the 2.1 installer, it was altered to create
#    randomized service passwords instead of consistent defaults. In
#    order to use this script effectively in a multi-host deployment,
#    service passwords should be specified consistently across all hosts
#    (see the "Service users and passwords" section).
#
# 2. Prior to 2.2, the installer defaulted to installing all known
#    cartridges shipped for OSE. Beginning with OSE 2.2, the default
#    set of cartridges will not include JBoss EAP or any other cartridges
#    that require an add-on subscription (including Fuse and AM-Q).
#    Customers with the necessary subscriptions can specify extra
#    cartridges desired with the CONF_CARTRIDGES parameter, e.g.:
#      # export CONF_CARTRIDGES=standard,jbosseap,fuse,amq
#    Deprecated NO_JBOSSEAP/EWS options are now removed entirely.
#
# 3. While mod_rewrite was the default node host frontend for OSE 2.1,
#    vhost is the default in OSE 2.2 and mod_rewrite is considered
#    deprecated. It is not recommended to deploy nodes with different
#    frontends within the same deployment, as moving gears between
#    these nodes may be problematic. Consult http://red.ht/1sau3Tq for
#    directions on how to change the frontend for an existing node host.
#    You must set CONF_NODE_APACHE_FRONTEND=mod_rewrite if you wish to
#    install a node using the deprecated frontend.
#
# 4. Prior to 2.2, network isolation for gears was not applied by default.
#    Without isolation, gears could bind and connect to localhost as well
#    as IPs belonging to other gears. Beginning with 2.2, oo-gear-firewall
#    is invoked by default at installation in order to prevent this.
#    Note that this is done prior to districting, so you may need to re-run
#    oo-gear-firewall after the node has been put in a district if it has
#    a non-standard UID range. See CONF_ISOLATE_GEARS for details.

# SPECIFYING PARAMETERS
#
# If you supply no parameters, all components are installed on one host
# with default configuration, which should give you a running demo,
# given properly configured repositories / subscriptions on the host.
#
# Available parameters are listed at length below the following notes.
# The method of specifying parameters depends on how this is used.
#
# If you are using the extracted openshift.sh version of this
# script, the parse_cmdline function enables specifying the lowercase
# parameters on the command line, e.g.:
#   sh openshift.sh domain=example.com
#
# As a bash script in any context, you can just add the uppercase
# parameters as bash variables at the top of the script (or exported
# environment variables). Lowercase parameters are mapped to uppercase
# bash variables prepended with CONF_ so for example, "domain=example.com"
# as a command-line parameter would be "CONF_DOMAIN=example.com" as
# a variable.
#   export CONF_DOMAIN=example.com
#   sh openshift.sh
#
# For a kickstart, you can supply kernel parameters (in addition
# to the ks=location itself) with the lowercase form.  e.g.
#   virt-install ... -x "ks=http://.../openshift.ks domain=example.com"

# INSTALLATION REPOSITORIES
#
# Configuring sources for yum to install packages can be the hardest part
# of an installation. This script enables several methods to automatically
# configure the necessary repositories, which are described in parameters
# below. If you already configured repositories prior to running this
# script, you may leave the default method (which is to do nothing);
# otherwise you will need to modify the script or provide parameters
# to configure install sources. Be aware that correct yum configuration
# involves configuring repo priorities and exclusions, not just enabling
# repositories.
#
# If this script aborts due to an inability to install packages (the most
# common failure), it should be safe to re-run once you've resolved the
# problem (i.e. either manually fix configuration and run with
# install_method=none, or unregister / remove all repos and start over).
# Once package installation completes and configuration begins, aborts
# are unlikely; but in the event that one occurs, re-running could
# introduce misconfigurations as configure steps do not all include
# enough intelligence to be repeatable.
#
# DO NOT install with third-party (non-RHEL) repos enabled (e.g. EPEL).
# You may install different package versions than OpenShift expects and
# be in for a long troubleshooting session. Also avoid pre-installing
# third-party software like Puppet for the same reason.
#
# When used as a kickstart, for the %post section to succeed, yum must have
# access to the latest RHEL 6 packages. The %post section does not share the
# method used in the base install (HTTP, DVD, etc.). Either by modifying
# the base install, the %post script, or the script parameters, you must
# ensure that subscriptions or plain yum repos are available for RHEL.
#
# Similarly, the main OpenShift dependencies require OpenShift repos, and
# JBoss cartridges require packages from JBoss repos, so you must ensure
# these are configured for the %post script to run. Due to the complexity
# involved in this configuration, we recommend specifying parameters to
# use one of the script's install methods.

# OTHER IMPORTANT NOTES
#
# If used as a kickstart, you will almost certainly want to change the
# root password or authorized keys (or both) specified in the kickstart,
# and/or set up another user/group with sudo access so that you can
# access the system after installation.
#
# If you install a broker, the rhc client is installed as well, for
# convenient local testing. Also, a test user "demo" is created in
# /etc/openshift/htpasswd for use with the default broker authentication.
#
# If you want to use the broker from a client outside the installation,
# then of course that client must be using a DNS server that knows
# about (or is) the DNS server for the installation. Otherwise you will
# have DNS failures when creating the app and be unable to reach it in a
# browser.
#

# POST-DEPLOY STEP
#
# After installing and configuring all hosts in a deployment, the
# broker must issue commands to district its nodes and import cartridges
# from its nodes. Because this relies on node deployment being completed,
# this step must usually be performed separately from the regular broker
# deployment and is not performed by default.
#
# This script can perform this step via the post_deploy action.
#   sh openshift.sh action=post_deploy

# MANUAL TASKS
#
# This script attempts to automate as many tasks as it reasonably can.
# Because it deploys only a single host at a time, it has some limitations.
# In a multi-host setup, you may need to attend to the following
# concerns separately from this script:
#
# 1. Set up DNS entries for hosts
#    Generally, all hosts in your deployment should have DNS entries.
#    Node hosts strictly require DNS entries in order to alias CNAMEs.
#    If you install named with this script, you can opt to define DNS
#    entries for your hosts. By default, any other components the script
#    installs on the same host with named receive DNS entries. Or, you
#    can use CONF_NAMED_ENTRIES to specify (or skip) host DNS creation.
#    Host DNS entries not created this way must be created separately.
#    oo-register-dns on the broker may be useful for this.
#
# 2. Copy public rsync key to enable moving gears
#    The broker rsync public key needs to be authorized on nodes. The
#    install script puts a copy of the public key on the broker web
#    server so that nodes can get it at install time, so this script
#    can get it after the broker install finishes. If that fails for
#    any reason, install it manually as follows:
#       #  wget -O- --no-check-certificate https://broker/rsync_id_rsa.pub >> /root/.ssh/authorized_keys
#    Without this, each gear move will require typing root passwords
#    for each of the node hosts involved.
#
# 3. Copy ssh host keys and httpd key/cert between the node hosts
#    All node hosts should identify as the same host, so that when gears
#    are moved between hosts, ssh and git don't give developers spurious
#    warnings about the host keys changing. So, copy /etc/ssh/ssh_* from
#    one node host to all the rest (or, if using the same image for all
#    hosts, just keep the keys from the image). Similarly, https access
#    to moved gears will prompt errors if the certificate is not
#    identical across nodes, so copy /etc/pki/tls/private/localhost.key
#    and /etc/pki/tls/certs/localhost.crt (which are re-created by the
#    installation) to be the same across all nodes.
#
# 4. When multiple broker hosts are deployed, copy the auth keys between
#    them so that they are the same (/etc/openshift/server_*.pem as
#    specified in broker.conf) and so is the broker.conf:AUTH_SALT (which
#    can be specified in this script with the CONF_BROKER_AUTH_SALT
#    parameter). Failure to synchronize these will result in failures in
#    scenarios where gears make requests to a broker while using
#    credentials created by a different broker - auto-scaling, Jenkins
#    builds, and recording deployments.

###########################################################################
#
# PARAMETER DESCRIPTIONS

#----------------------------------------------------------#
#                  General script options                  #
#----------------------------------------------------------#

# install_components / CONF_INSTALL_COMPONENTS
#   Comma-separated selections from the following:
#     broker - installs the broker webapp and tools
#     named - installs a BIND DNS server
#     activemq - installs the messaging bus
#     datastore - installs the MongoDB datastore
#     node - installs node functionality
#     router - installs nginx as an external load-balancer/routing layer
#   Default: all but router.
#   Only the specified components are installed and configured.
#   e.g. install_components=broker,datastore only installs the broker
#   and DB, and assumes you have used other hosts for messaging and DNS.
#
# Example kickstart parameter:
#  install_components="node,broker,named,activemq,datastore"
# Example script variable:
#  CONF_INSTALL_COMPONENTS="node,broker,named,activemq,datastore"
#CONF_INSTALL_COMPONENTS="node"

# install_method / CONF_INSTALL_METHOD
#   Choose from the following methods to configure yum for RPM installation:
#     none - install sources are already configured when the script executes (DEFAULT)
#     rhsm - use subscription-manager (RHSM)
#       rhn_user / CONF_RHN_USER
#       rhn_pass / CONF_RHN_PASS
#       rhn_reg_opts / CONF_RHN_REG_OPTS - extra options to subscription-manager register,
#                     e.g. "--serverurl=https://sam.example.com"
#       sm_reg_pool / CONF_SM_REG_POOL - pool ID for OpenShift subscription (required)
#                     Subscribe multiple with comma-separated list poolid1,poolid2,...
#     rhn - use rhn-register (RHN Classic)
#       rhn_user / CONF_RHN_USER
#       rhn_pass / CONF_RHN_PASS
#       rhn_reg_opts / CONF_RHN_REG_OPTS - extra options to rhnreg_ks,
#                     e.g. "--serverUrl=https://satellite.example.com"
#       rhn_reg_actkey / CONF_RHN_REG_ACTKEY - optional activation key
#     yum - configure plain old yum repos; refer to later section for usage
#   Default: none
#CONF_INSTALL_METHOD="rhsm"
# Hint: when running as a cmdline script, to enter your password invisibly:
#  read -s CONF_RHN_PASS
#  export CONF_RHN_PASS

# actions / CONF_ACTIONS
#   Default: do_all_actions
#   Comma-separated list of bash functions to run.  This
#   setting is intended to allow configuration steps defined within this
#   file to be run or re-run selectively.  For a typical installation,
#   this setting can be left at its default value, but note the example
#   below for the all-in-one case.
#
#   Some helpful actions:
#     init_message,validate_preflight,configure_repos,
#     install_rpms,configure_host,configure_openshift,
#     configure_datastore_add_replicants,post_deploy
#
# For example, these are the actions to run on a primary MongoDB replicant:
#CONF_ACTIONS=do_all_actions,configure_datastore_add_replicants
# For an all-in-one host, the post_deploy action completes configuration:
#CONF_ACTIONS=do_all_actions,post_deploy
# (normally post_deploy should only run on the broker after all nodes are done)

# abort_on_unrecognized_settings / CONF_ABORT_ON_UNRECOGNIZED_SETTINGS
#   Default: true (automatically set to false for kickstarts)
#   Enabling this option causes the installation script to abort when
#   unrecognized settings, which could be typos or deprecated settings,
#   are specified.
#
#  If the installation script is used to kickstart a host, then the
#  script reads the kernel command-line for arguments to the kickstart
#  installation.  Because the kernel command-line is likely to have
#  arguments that are unrelated to the installation script, the script
#  will override the default and set it to false during kickstarts.
#CONF_ABORT_ON_UNRECOGNIZED_SETTINGS=false

#----------------------------------------------------------#
#               Service users and passwords                #
#----------------------------------------------------------#

# Passwords are used to secure various services. In a typical deployment
# at least some services will need to be accessed by clients on other
# hosts, so all hosts need to know the same service user/pass.
#
# As a secure default, passwords are set to randomized values which will not
# match between hosts. To get matching values, either set them explicitly
# or disable the randomizing in order to use shared (and thus not secure)
# defaults. oo-install coordinates multi-host deployments by setting
# secure randomized values across all hosts. http://red.ht/1uocikk
#
# You are advised to specify only alphanumeric users/passwords as
# others may cause syntax errors depending on context. If non-alphanumeric
# values are required, update them separately after installation.
#
# no_scramble / CONF_NO_SCRAMBLE
#   Default: false
#   This flag determines whether default passwords should be randomized
#   or set to insecure defaults.

# mcollective_user / CONF_MCOLLECTIVE_USER
# mcollective_password / CONF_MCOLLECTIVE_PASSWORD
#   Default: mcollective/<randomized>
#   Default with CONF_NO_SCRAMBLE: mcollective/marionette
#   This is the user and password shared between broker and node for
#   communicating over the mcollective topic channels in ActiveMQ. Must
#   be the same on all broker and node hosts.
#CONF_MCOLLECTIVE_USER="mcollective"
#CONF_MCOLLECTIVE_PASSWORD="mcollective"
#
# activemq_admin_password / CONF_ACTIVEMQ_ADMIN_PASSWORD
#   Default: <randomized>
#   This is the admin password for the ActiveMQ admin console, which is
#   not needed by OpenShift but might be useful in troubleshooting.
#CONF_ACTIVEMQ_ADMIN_PASSWORD="ChangeMe"

# mongodb_name / CONF_MONGODB_NAME
#   Default: openshift_broker
#   This is the name of the database in MongoDB in which the broker will
#   store data.
#CONF_MONGODB_NAME="openshift_broker"
#
# mongodb_broker_user / CONF_MONGODB_BROKER_USER
# mongodb_broker_password / CONF_MONGODB_BROKER_PASSWORD
#   Default: openshift:<randomized>
#   Default with CONF_NO_SCRAMBLE: openshift:mongopass
#   These are the username and password of the normal user that will be
#   created for the broker to connect to the MongoDB datastore. The
#   broker application's MongoDB plugin is also configured with these
#   values.
#CONF_MONGODB_BROKER_USER="openshift"
#CONF_MONGODB_BROKER_PASSWORD="mongopass"
#
# mongodb_admin_user / CONF_MONGODB_ADMIN_USER
# mongodb_admin_password / CONF_MONGODB_ADMIN_PASSWORD
#   Default: admin:<randomized>
#   Default with CONF_NO_SCRAMBLE: admin:mongopass
#   These are the username and password of the administrative user that
#   will be created in the MongoDB datastore. These credentials are not
#   used by in this script or by OpenShift, but an administrative user
#   must be added to MongoDB in order for it to enforce authentication.
#   Note: The administrative user will not be created if
#   CONF_NO_DATASTORE_AUTH_FOR_LOCALHOST is enabled.
#CONF_MONGODB_ADMIN_USER="admin"
#CONF_MONGODB_ADMIN_PASSWORD="mongopass"

# openshift_user1 / CONF_OPENSHIFT_USER1
# openshift_password1 / CONF_OPENSHIFT_PASSWORD1
#   Default: demo/<randomized>
#   Default with CONF_NO_SCRAMBLE: demo/changeme
#   This user and password are entered in the /etc/openshift/htpasswd
#   file as a demo/test user. You will likely want to remove it after
#   installation (or just use a different auth method).
#CONF_OPENSHIFT_USER1="demo"
#CONF_OPENSHIFT_PASSWORD1="changeme"

# broker_auth_salt / CONF_BROKER_AUTH_SALT
#   Should be the same on all brokers!
#CONF_BROKER_AUTH_SALT=""
#
# broker_session_secret / CONF_BROKER_SESSION_SECRET
#   Should be the same on all brokers!
#CONF_BROKER_SESSION_SECRET=""
#
# console_session_secret / CONF_CONSOLE_SESSION_SECRET
#   Should be the same on all brokers!
#CONF_CONSOLE_SESSION_SECRET=""

# broker_auth_priv_key / CONF_BROKER_AUTH_PRIV_KEY
#   Should be the same on all brokers!
#CONF_BROKER_AUTH_PRIV_KEY=""

#----------------------------------------------------------#
#                 Parameters for all hosts                 #
#----------------------------------------------------------#

# domain / CONF_DOMAIN
#   Default: example.com
#   The cloud domain under which app DNS entries will be created.
#CONF_DOMAIN="example.com"

# keep_nameservers / CONF_KEEP_NAMESERVERS
#   Default: false (not set)
#   Enabling this option prevents the installation script from placing
#   the OpenShift nameserver at the top of /etc/resolv.conf, which is
#   the default (because rogue DNS is assumed). Set this to true if
#   OpenShift app DNS is properly delegated/authoritative.
#CONF_KEEP_NAMESERVERS=true
#
# named_ip_addr / CONF_NAMED_IP_ADDR
#   Default: current IP if installing named, otherwise broker_ip_addr
#   This is used by every host to configure its primary nameserver
#   unless keep_nameservers is true.
#CONF_NAMED_IP_ADDR=10.10.10.10

# keep_hostname / CONF_KEEP_HOSTNAME
#   Default: false (not set)
#   Enabling this option prevents the installation script from setting
#   the hostname on the host, leaving it as found.  Use this option if
#   the hostname is already set as you like. The default behavior is
#   to set the hostname, which makes it a little easier to recognize
#   which host you are looking at when logging in as an administrator.
#   The hostname is also used as a node's mcollective server_identity.
#CONF_KEEP_HOSTNAME=true

# broker_hostname / CONF_BROKER_HOSTNAME
# node_hostname / CONF_NODE_HOSTNAME
# named_hostname / CONF_NAMED_HOSTNAME
# activemq_hostname / CONF_ACTIVEMQ_HOSTNAME
# datastore_hostname / CONF_DATASTORE_HOSTNAME
# router_hostname / CONF_ROUTER_HOSTNAME
#   Default: the root plus the host domain, e.g. broker.example.com - except
#   named=ns1.example.com and router=www.example.com
#
#   These supply the FQDN of the hosts containing these components. Used
#   for configuring the host's name at install, and also for clients to
#   access services on specific hosts.
#
#   The broker must access ActiveMQ and the datastore.
#   Nodes must access ActiveMQ and the broker (could be a LB/VIP).
#   These should be correct even if the service is on the local host.
#
#   If installing a BIND nameserver, the script by default
#   uses these values to create DNS entries for the hostnames of any
#   components being installed on the same host as BIND.
#
#CONF_BROKER_HOSTNAME="broker.example.com"
#CONF_NODE_HOSTNAME="node.example.com"
#CONF_NAMED_HOSTNAME="ns1.example.com"
#CONF_ACTIVEMQ_HOSTNAME="activemq.example.com"
#CONF_DATASTORE_HOSTNAME="datastore.example.com"
#CONF_ROUTER_HOSTNAME="www.example.com"

# syslog / CONF_SYSLOG
#   Default: log only to files
#   Specify which components log to the syslog.
#   Comma or space-separated options include:
#     broker - broker rails app server logs
#     console - console rails app server logs
#     node - node platform logs
#     frontend - host httpd access logs
#     gears - gear app server logs
#CONF_SYSLOG="broker,console,node,frontend,gears"

# interface / CONF_INTERFACE
#   Default: eth0
#   The network device to configure.  Used by configure_network,
#   configure_dns_resolution, and configure_node
#CONF_INTERFACE="eth0"

# no_ntp / CONF_NO_NTP
#   Default: false
#   Enabling this option prevents the installation script from
#   configuring NTP.  It is important that the time be synchronized
#   across hosts because MCollective messages have a TTL of 60 seconds
#   and may be dropped if the clocks are too far out of synch.  However,
#   NTP is not necessary if the clock will be kept in synch by some
#   other means.
#CONF_NO_NTP=true

# http_proxy / CONF_HTTP_PROXY
# https_proxy / CONF_HTTPS_PROXY
#   Default: none
#   Setting these options causes the installation script to configure the PaaS
#   to use the specified proxy or proxies for access to external resources via
#   HTTP and HTTPS.  For example, /etc/gitconfig will be written on broker and
#   node hosts, which both need Git to clone downloadable cartridges, and
#   /etc/openshift/env/HTTP_PROXY, /etc/openshift/env/HTTPS_PROXY, and
#   /etc/openshift/env/NO_PROXY (to exclude internal addresses) will be written
#   as appropriate so that gears will have the corresponding environment
#   variables, which may be needed for cartridge-specific package repositories
#   (e.g., Maven for JBoss, NPM for NodeJS, and Pear for PHP).
#CONF_HTTP_PROXY='http://10.0.0.1:80/'
#CONF_HTTPS_PROXY='https://10.0.0.1:443/'

#----------------------------------------------------------#
#                          Brokers                         #
#----------------------------------------------------------#

# broker.conf settings for node/gear profiles:
#
# valid_gear_sizes / CONF_VALID_GEAR_SIZES   (comma-separated list)
#CONF_VALID_GEAR_SIZES="small"
#
# default_gear_capabilities / CONF_DEFAULT_GEAR_CAPABILITIES (comma separated list)
#CONF_DEFAULT_GEAR_CAPABILITIES="small"
#
# default_gear_size / CONF_DEFAULT_GEAR_SIZE
#CONF_DEFAULT_GEAR_SIZE="small"

#default_districts / CONF_DEFAULT_DISTRICTS
#   Default: true
#   When enabled (and executing the post_deploy action), a district will be
#   created for each entry in valid_gear_sizes/CONF_VALID_GEAR_SIZES
#   and all non-districted nodes of that size will be added to the default
#   district matching that size.
#CONF_DEFAULT_DISTRICTS=true
#
#district_mappings / CONF_DISTRICT_MAPPINGS
#   A string describing district/node mappings to be created during the
#   post_deploy action.  default_districts/CONF_DEFAULT_DISTRICTS
#   must be set to false for this variable to have an effect.
#CONF_DISTRICT_MAPPINGS="district1:node1.hosts.example.com,node2.hosts.example.com;district2:node3.hosts.example.com;district3:node4.hosts.example.com,node5.hosts.example.com"
#
#district_first_uid / CONF_DISTRICT_FIRST_UID
#   Default: 1000
#   Districts will be created on the broker with a pool of gear UIDs
#   beginning at this number. Should be between 1000 and 500,000.
#   These UIDs will be used for gears on nodes.
#   If specified for a node install, gear isolation rules will start at
#   this UID as well.

# routing_plugin / CONF_ROUTING_PLUGIN
# routing_plugin_user / CONF_ROUTING_PLUGIN_USER
# routing_plugin_pass / CONF_ROUTING_PLUGIN_PASS
#   Default: install the routing plugin if CONF_INSTALL_COMPONENTS includes
#   "broker" and CONF_ROUTER is non-empty; otherwise, do not install it.
#   When enabled, the routing plugin publishes routing events to a topic
#   on the ActiveMQ instance(s) used by OpenShift Enterprise.
#   For more info: http://red.ht/1eG9lHr
#CONF_ROUTING_PLUGIN=true
#CONF_ROUTING_PLUGIN_USER=routinginfo
#CONF_ROUTING_PLUGIN_PASS=...
#   Default: <randomized>
#   Default with CONF_NO_SCRAMBLE: routinginfopasswd

# enable_ha / CONF_ENABLE_HA
#   Default: false
#   When enabled, this installation script will configure the OpenShift broker
#   to allow HA applications (setting ALLOW_HA_APPLICATIONS=true in
#   /etc/openshift/broker.conf), add DNS CNAME records for highly available
#   access to applications (MANAGE_HA_DNS=true in broker.conf) where those CNAME
#   records will point to an external load-balancer (see CONF_ROUTER_HOSTNAME),
#   and configure the broker so that accounts have permission to create HA
#   applications by default (DEFAULT_ALLOW_HA=true in broker.conf).
#CONF_ENABLE_HA=true

# router / CONF_ROUTER
#   Default: none
#   When CONF_INSTALL_COMPONENTS includes router or broker, this setting
#   specifies the router that will be installed or configured.  The following
#   values are recognized:
#     nginx - install and configure nginx and the routing daemon when
#       CONF_INSTALL_COMPONENTS includes "router".
#     f5 - install and configure the routing daemon for F5 BIG-IP LTM when
#       CONF_INSTALL_COMPONENTS includes "broker".
#   Note that installing and configuring F5 itself is outside the scope of this
#   installation script.  Also note that in the case of F5, the routing daemon
#   must run on the broker hosts whereas in the case of nginx, the routing
#   daemon must run on the router alongside nginx.
#CONF_ROUTER=f5
#CONF_ROUTER=nginx

# Settings for configuring Kerberos as user authentication method
#
# The KrbServiceName value for mod_auth_kerb configuration
#CONF_BROKER_KRB_SERVICE_NAME=""
#
# The KrbAuthRealms value for mod_auth_kerb configuration
#CONF_BROKER_KRB_AUTH_REALMS=""
#
# The Krb5KeyTab value of mod_auth_kerb is not configurable -- the keytab
# is expected in /var/www/openshift/broker/httpd/conf.d/http.keytab

#----------------------------------------------------------#
#                        DNS service                       #
#----------------------------------------------------------#

# For demonstration purposes, OpenShift installs BIND to serve as its
# DNS service. This service can be configured with host names in the
# deployment as well as supporting dynamic updates to the app domain.
#
# This BIND server can be delegated as an authoritative server for an
# actual deployment, but many administrators may wish to reuse an
# existing DNS service with OpenShift or set up one independently.
# Parameters exist to configure for all of these possibilities.
# However, this script does not configure non-standard DDNS plugins.

# The broker needs a key for updating dynamic DNS. This key should be
# configured into BIND if installed for use with the deployment.
#
# bind_key / CONF_BIND_KEY
#   Specify a key for updating the app domain, whether the service is
#   BIND or something else. If not set, one is generated.
#   Any base64-encoded value can be used, but ideally an HMAC-SHA256 key
#   generated by dnssec-keygen should be used.
#CONF_BIND_KEY=""
#
# bind_keyalgorithm / CONF_BIND_KEYALGORITHM
#   The key algorithm used for generating the bind_key.
#   (Specify for separate service using a different algorithm.)
#CONF_BIND_KEYALGORITHM="HMAC-SHA256"
#
# bind_keysize / CONF_BIND_KEYSIZE
#   The key size used for generating a bind key, if not default 256.
#CONF_BIND_KEYSIZE="256"

# To use kerberos authentication rather than a key to update DNS:
#
# bind_krb_keytab / CONF_BIND_KRB_KEYTAB
#   When the nameserver is remote, Kerberos keytab together with principal
#   can be used instead of the HMAC-SHA256 key for updates.
#CONF_BIND_KRB_KEYTAB=""
#
# bind_krb_principal / CONF_BIND_KRB_PRINCIPAL
#   When the nameserver is remote, this Kerberos principal together with
#   Kerberos keytab can be used instead of the HMAC-MD5 key for updates.
#CONF_BIND_KRB_PRINCIPAL=""

# When installing BIND, it can be configured with a host domain and
# entries for hosts in the deployment.
#
# named_entries / CONF_NAMED_ENTRIES
#   Comma separated, colon delimited hostname:ipaddress pairs
#   You may also set to "none" to create no DNS entries for hosts.
#   Default: entries for components installed on this host.
#
#   Specify host DNS entries to be created under the hosts_domain.
#   $hosts_domain is appended if not included.
#CONF_NAMED_ENTRIES="broker:192.168.0.1,node:192.168.0.2"
#
# hosts_domain / CONF_HOSTS_DOMAIN
#   Default: $CONF_DOMAIN (example.com)
#   If host DNS entries are to be created, this domain will be created
#   and used for host DNS records (app records will still go in the
#   main domain).
#CONF_HOSTS_DOMAIN="hosts.example.com"
#
# hosts_domain_keyfile / CONF_HOSTS_DOMAIN_KEYFILE
#   Default: "/var/named/${hosts_domain}.key"
#   If specified and calling register_named_entries, the specified keyfile
#   will be used for updating the entries.
#CONF_HOSTS_DOMAIN_KEYFILE="/var/named/hosts.example.com.key"
#
# broker_ip_addr / CONF_BROKER_IP_ADDR
#   Default: the current IP (at install)
#   IP address to register for the broker hostname.
#   Used for the nameserver IP if none specified.
#CONF_BROKER_IP_ADDR=10.10.10.10

# forward_dns / CONF_FORWARD_DNS
#   Default: false (not set)
#   This option determines whether the BIND server being installed will
#   forward requests for which it is not authoritative to upstream DNS
#   servers. This should not be necessary in most cases; with this
#   disabled, BIND will refuse requests (status REFUSED) that it
#   cannot answer directly, which should cause most clients to ask the
#   next nameserver in their configuration.
#CONF_FORWARD_DNS=true

#----------------------------------------------------------#
#             Redundant MongoDB and ActiveMQ               #
#----------------------------------------------------------#

# datastore_replicants / CONF_DATASTORE_REPLICANTS
#   Default: the value of datastore_hostname (no replication)
#   A comma-separated list of MongoDB replicants to be used as a replica set.
#   Each replicant must be represented by a hostname and, optionally, a colon
#   and port number.  For each replicant, if you omit the port specification
#   for that replicant, port :27017 will be appended.
#
#   To install and configure a HA replica set, install at least three
#   hosts with the datastore component, and when all are complete,
#   all hostnames resolve and all databases are reachable,
#   on one host execute the configure_datastore_add_replicants
#   action to configure the replica set; e.g. (on the last host only):
#CONF_ACTIONS=do_all_actions,configure_datastore_add_replicants
#   All hosts should be installed with all replicants specified:
#CONF_DATASTORE_REPLICANTS="datastore01.example.com:27017,datastore02.example.com:27017,datastore03.example.com:27017"
#
# mongodb_replset / CONF_MONGODB_REPLSET
#   Default: ose
#   In a replicated setup, this is the shared name of the replica set.
#CONF_MONGODB_REPLSET="ose"
#
# mongodb_key / CONF_MONGODB_KEY
#   Default: <randomized>
#   Default with CONF_NO_SCRAMBLE: OSEnterprise
#   In a replicated setup, this is the key that slaves will use to
#   authenticate with the master.
#CONF_MONGODB_KEY="OSEnterprise"

# activemq_replicants / CONF_ACTIVEMQ_REPLICANTS
#   Default: the value of activemq_hostname (no replication)
#   A comma-separated list of ActiveMQ broker replicants.  Each replicant must
#   be represented by a hostname without a port number (port 61613 is assumed).
#   If you are not installing in a configuration with ActiveMQ replication, you
#   can leave this setting at its default value.
#CONF_ACTIVEMQ_REPLICANTS="activemq01.example.com,activemq02.example.com"
#
# activemq_amq_user_password / CONF_ACTIVEMQ_AMQ_USER_PASSWORD
#   Default: <randomized>
#   Default with CONF_NO_SCRAMBLE: password
#   This is the password for the ActiveMQ amq user, which is
#   used by ActiveMQ broker replicants to communicate with one another.
#   The amq user is enabled only if replicants are specified using
#   the activemq_replicants setting.
#CONF_ACTIVEMQ_AMQ_USER_PASSWORD="ChangeMe"

#----------------------------------------------------------#
#                         Node hosts                       #
#----------------------------------------------------------#

# Set profile and resource_limits on the node.
# A node profile (AKA "gear size") is just a name. The actual resource limits
# configured for a profile may vary by node host; for example, specific nodes
# may have more CPUs or RAM than others, or live on a more costly network.
# openshift.sh will use the profile and node type to choose one from a listing
# of resource_limits.conf files as follows:
#
# 1. If /etc/openshift/resource_limits.conf.$profile.$type exists, use that.
# 2. Else, if /etc/openshift/resource_limits.conf.$profile exists, use that.
# 3. Else, just change the profile name in /etc/openshift/resource_limits.conf
#
# OpenShift installs four resource_limits.conf examples with profiles
# "small", "medium", "large", and "xpaas" for type "m3.xlarge".
# Any others in place when this script runs could also be used.
#
#
# node_host_type / CONF_NODE_HOST_TYPE
#   Default: m3.xlarge (Amazon EC2 VM type)
#CONF_NODE_HOST_TYPE=""
#
# Set profile on the node.
# node_profile / CONF_NODE_PROFILE
#   Default: small
#CONF_NODE_PROFILE="medium"
#
# Set different profile name on the node (while still using one of the
# standard profile example configurations with CONF_NODE_PROFILE).
# node_profile_name / CONF_NODE_PROFILE_NAME
#CONF_NODE_PROFILE_NAME="small.internal"

# cartridges / CONF_CARTRIDGES
#   Comma-separated selections from the following:
#     all - all cartridges;
#     standard - all cartridges that do not require a premium subscription;
#     stdframework - all framework cartridges from "standard";
#     stdaddon - all add-on cartridges from "standard";
#     premium - all cartridges that do require a premium subscription;
#     cron - embedded cron support;
#     diy - do-it-yourself cartridge;
#     haproxy - haproxy support for scalable apps;
#     amq - JBoss AM-Q support; (a premium subscription)
#     fuse - JBoss Fuse support; (a premium subscription)
#     fuse-builder - Fuse builder support; (fuse or amq subscription)
#     jbossews - JBossEWS support;
#     jbosseap - JBossEAP support; (a premium subscription)
#     jboss - alias for jbossews and jbosseap;
#     jenkins - Jenkins client and server for continuous integration;
#     mongodb - MongoDB;
#     mysql - MySQL;
#     nodejs - NodeJS;
#     perl - mod_perl support;
#     php - PHP support;
#     postgresql - PostgreSQL support;
#     postgres - alias for postgresql;
#     python - Python support;
#     ruby - Ruby Rack support running on Phusion Passenger.
#
#   You may prepend a minus sign '-' to any one of the above to negate it.
#   E.g.: standard,-jbossews enables standard cartridges except for jbossews.
#
#   You may also specify a package name; any selection that is not in the above
#   list will be assumed to be a package name and will be added to (or removed
#   from) the list of packages to install, verbatim.
#
#   Selections are read from left to right.  For example, all,-jboss,jbossews
#   enables all cartridges except for JBoss cartridges, except for JBossEWS (so
#   JBossEWS _will_ be enabled but JBossEAP will _not_ be enabled).  However,
#   all,jbossews,-jboss would install all cartridges except for JBoss cartridges
#   (so neither JBossEWS nor JBossEAP will be installed).
#
#   If support for premium cartridges is selected, this script will
#   ensure that the required channels or repositories are enabled,
#   and fail if they are not available under your subscription.
#   Default: standard

# jbosseap_version / CONF_JBOSSEAP_VERSION
#   Default: 6.3
#   Specify which version of JBoss EAP channel is desired.
#   Valid options include:
#     6.3 - Enable the channel(s) carrying JBoss EAP 6.3
#     6.4 - Enable the channel(s) carrying JBoss EAP 6.4
#     current - Enable the channel(s) carrying the most recent JBoss
#               EAP release
#CONF_JBOSSEAP_VERSION=6.3

# metapkgs / CONF_METAPKGS
#   Default: recommended
#   Specify which cartridge dependency metapackages should be installed
#   Comma or space-separated options include:
#     none - Install none of the cart dep metapackages
#     recommended - Install only the recommended cart dep metapackages
#     optional - Install the optional AND recommended cart dep metapackages
# CONF_METAPKGS=optional

# Various node front end proxies for accessing gears.
#
# Node httpd proxy frontend. Valid options are vhost and mod_rewrite.
# mod_rewrite is intended for nodes with thousands of gears (mostly idle).
# vhost is not as scalable but more extensible and under typical usage,
# more performant.
# NOTE: While mod_rewrite was the default for OSE 2.1, vhost is
# the default in OSE 2.2 and mod_rewrite is considered
# deprecated. It is not recommended to deploy nodes with different
# frontends within the same deployment, as moving gears between
# these nodes may be problematic. Consult http://red.ht/1sau3Tq for
# directions on how to change the frontend for an existing node host.
#CONF_NODE_APACHE_FRONTEND=vhost
#
# enable_sni_proxy / CONF_ENABLE_SNI_PROXY
#   Default: false (but true for "xpaas" profile)
#   Whether to enable the node sni proxy frontend.
#CONF_ENABLE_SNI_PROXY=false
#
# sni_first_port / CONF_SNI_FIRST_PORT
#   Default: 2303
# sni_proxy_ports / CONF_SNI_PROXY_PORTS
#   Default: 5 (10 for "xpaas" profile)
# Number of ports exposed and bound to the SNI proxy, beginning at first.
#CONF_SNI_PROXY_PORTS=5
#
# ports_per_gear / CONF_PORTS_PER_GEAR
#   Default: 5 (15 for "xpaas" profile)
# External ports to allocate per gear. Change with caution; increasing
# the ports per gear requires reducing the number of UIDs the district
# is created with so that the port requirement for the district is not
# larger than the external port range of its nodes.
#CONF_PORTS_PER_GEAR=5

# idle_interval / CONF_IDLE_INTERVAL
#   Default: do not idle gears on the node
#   Specify the number of hours after which a gear should be idled if it
#   has not been accessed. Creates an hourly cron job to check for
#   inactive gears and idle them.
#CONF_IDLE_INTERVAL=240

# N.B.: see CONF_SYSLOG for directing logging to the syslog.
# node_log_context / CONF_NODE_LOG_CONTEXT
#   Default: disabled
#   When true, enables extra context annotations in the node and frontend
#   logs to indicate (where relevant) the request id on broker requests,
#   the application UUID and the gear UUID.
#CONF_NODE_LOG_CONTEXT=true

# metrics_interval / CONF_METRICS_INTERVAL
#   Default: metrics gathering disabled
#   Specify an interval (in seconds) at which to have watchman gather
#   gear metrics on a node. Lower values gather metrics more often,
#   using more CPU and filling the logs faster. There are many related
#   options available in node.conf; consult the Administration Guide.
#CONF_METRICS_INTERVAL=60

# node_ip_addr / CONF_NODE_IP_ADDR
#   Default: the current IP (at install)
#   This is used for the node to specify a public IP, if different from the
#   one on its NIC.
#CONF_NODE_IP_ADDR=10.10.10.10

# isolate_gears / CONF_ISOLATE_GEARS
#   Default: true
#   If true, the node will be configured with network isolation such that
#   gears cannot bind or connect to internal IPs belonging to other gears.
#   The UID range covered begins at CONF_DISTRICT_FIRST_UID and ends 6000
#   later, which is the standard size of the gear UID range.
#   Note that this is done prior to districting, so you may need to re-run
#   oo-gear-firewall after the node has been put in a district if it has
#   a non-standard UID range.
#CONF_ISOLATE_GEARS=false

#----------------------------------------------------------#
#           Parameters for "yum" install method            #
#----------------------------------------------------------#

# This method defines "plain old" yum repositories (not from a
# subscription), mainly for internal test systems. This can also be
# used for offline installs. The assumed layout of the repositories is
# that of the CDN used with released products, which is:
#
# <base> = http(s)://server/.../x86_64   # top of x86_64 architecture tree
# <base>/jbeap/6/os         - JBoss repos
# <base>/jbews/2/os
# <base>/optional/os        - "optional" channel, not normally needed
# <base>/os                 - RHEL 6 itself
# <base>/ose-infra/2.2/os     - Released OpenShift Enterprise repos
# <base>/ose-node/2.2/os
# <base>/ose-rhc/2.2/os
# <base>/ose-jbosseap/2.2/os  - JBoss EAP cartridge
# <base>/ose-jbossamq/2.2/os  - JBoss AMQ cartridge
# <base>/ose-jbossfuse/2.2/os - JBoss Fuse cartridge
# <base>/rhscl/1/os/        - RH software collections
#
# To use this layout, simply set the CDN base URL below. Alternatively,
# set repository URLs individually if they are in different locations.
# yum repository definitions will be created with any parameters provided;
# otherwise they should already be defined for installation to succeed.
#
# The nightly OSE build repositories use a different layout from CDN.
# If the location of these is different from the CDN base and CONF_CDN_LAYOUT
# is not set, then this layout is defined:
# <ose_repo_base>/RHOSE-CLIENT-2.2/x86_64/os
# <ose_repo_base>/RHOSE-INFRA-2.2/x86_64/os
# <ose_repo_base>/RHOSE-JBOSSEAP-2.2/x86_64/os
# <ose_repo_base>/RHOSE-NODE-2.2/x86_64/os

# cdn_repo_base / CONF_CDN_REPO_BASE
#   Default base URL for all repositories used for the "yum" install method (see above).
#CONF_CDN_REPO_BASE=https://.../6Server/x86_64

# ose_repo_base / CONF_OSE_REPO_BASE
#   If defined, will define yum repos under the yum,rhsm,rhn install methods.
#   The base URL for the OpenShift yum repositories - the part before RHOSE-*
#   Note that if this is the same as CONF_CDN_REPO_BASE, then the
#   CDN format will be used instead, e.g. x86_64/ose-node/2.2/os
#CONF_OSE_REPO_BASE="https://.../6Server/x86_64"

# rhel_repo / CONF_RHEL_REPO
#   The URL for a RHEL 6 yum repository used with the "yum" install method.
#   Should end in /6Server/x86_64/os/

# rhel_extra_repo / CONF_RHEL_EXTRA_REPO
#   If set, will define a yum repo under the yum,rhsm,rhn install
#   methods. This will parallel the regular RHEL channels/repos at the
#   same priority. The value of this option sets the "baseurl" setting
#   for the defined repo. Useful for testing prerelease content

# rhel_optional_repo / CONF_RHEL_OPTIONAL_REPO
#   The URL for a RHEL 6 Optional yum repository used with the "yum" install method.
#   (only used if CONF_OPTIONAL_REPO is true)
#   Should end in /6Server/x86_64/optional/os/

# jboss_repo_base / CONF_JBOSS_REPO_BASE
#   The base URL for the JBoss repositories used with the "yum"
#   install method - the part before jbeap/jbews - ends in /6Server/x86_64
#   Also used for Fuse/A-MQ cartridges.

# jbosseap_extra_repo / CONF_JBOSSEAP_EXTRA_REPO
#   If set, will define a yum repo under the yum,rhsm,rhn install
#   methods. This will parallel the regular JBoss channels/repos at
#   the same priority. The value of this option sets the "baseurl"
#   setting for the defined repo. Useful for testing prerelease
#   content

# jbossews_extra_repo / CONF_JBOSSEWS_EXTRA_REPO
#   If set, will define a yum repo under the yum,rhsm,rhn install
#   methods. This will parallel the regular JBoss channels/repos at
#   the same priority. The value of this option sets the "baseurl"
#   setting for the defined repo. Useful for testing prerelease
#   content

# fuse_extra_repo / CONF_FUSE_EXTRA_REPO
# amq_extra_repo / CONF_AMQ_EXTRA_REPO
#   If set, will define a yum repo under the yum,rhsm,rhn install methods.

# rhscl_repo_base / CONF_RHSCL_REPO_BASE
#   The base URL for the SCL repositories used with the "yum"
#   install method - the part before rhscl - ends in /6Server/x86_64

# rhscl_extra_repo / CONF_RHSCL_EXTRA_REPO
#   If set, will define a yum repo under the yum,rhsm,rhn install
#   methods. This will parallel the regular RHSCL channels/repos at
#   the same priority. The value of this option sets the "baseurl"
#   setting for the defined repo. Useful for testing prerelease
#   content

# ose_extra_repo_base / CONF_OSE_EXTRA_REPO_BASE -- see below
#   If defined, will define yum repos under the yum,rhsm,rhn install methods.
#   These parallel the regular OSE channels/repos at the same priority and use
#   the same (non-CDN) layout as ose_repo_base. These are intended to supply RPMs
#   that augment or update the contents of the normal channels/repos.

# optional_repo / CONF_OPTIONAL_REPO
#   Enable unsupported RHEL "optional" repo.
#   Not usually needed, but may help with temporary dependency mismatches
#   Default: no
#CONF_OPTIONAL_REPO=1

# yum_exclude_pkgs / CONF_YUM_EXCLUDE_PKGS
#   (not advised) Work around temporarily faulty dev yum repos by permanently excluding
#   missing packages from yum repos.
#CONF_YUM_EXCLUDE_PKGS="foo-1.1-2.el6_5 bar-1.2-3"


########################################################################


set -euo pipefail

#annotate()
#{
#  exec awk "{ print strftime(\"%H:%M:%S $1:\"), \$0; fflush(); }"
#}
#trap 'echo "Finished with exitcode $?" >&4' EXIT
## <> redirection requires disabling posix.
#set +o posix
#exec 5>&1 \
#  1<> >(annotate O >&5) \
#  2<> >(annotate E >&5) \
#  3<> >(annotate D >&5) \
#  4<> >(annotate I >&5) \
#  5>&-
#BASH_XTRACEFD=3
#echo "Started $0 $*" >&4


########################################################################

# Synchronize the system clock to the NTP servers and then synchronize
# hardware clock with that.
synchronize_clock()
{
  local need_to_start_ntpd=

  if service ntpd status | grep 'is running'
  then
    # Stop ntpd so that ntpdate succeeds.
    service ntpd stop
    need_to_start_ntpd=1
  fi

  # Synchronize the system clock using NTP.
  ntpdate clock.redhat.com

  [[ -n "$need_to_start_ntpd" ]] && service ntpd start

  # Synchronize the hardware clock to the system clock.
  hwclock --systohc
}

# Given a variable and a default password assign either the default
# password or a random password to the variable depending on the value
# of CONF_NO_SCRAMBLE/no_scramble
#
# $1 = variable to set
# $2 = default password to use
# $3 = env conf variable
assign_pass()
{
 # If the ENV variable is set, use it
  if [[ -n "${!3-}" ]]
  then
    printf -v "$1" '%s' "${!3}"
  elif is_true "$no_scramble"
  then
    printf -v "$1" '%s' "$2"
  else
    local randomized=$(openssl rand -base64 20)
    printf -v "$1" '%s' "${randomized//[![:alnum:]]}"
  fi
  passwords[$1]="${!1}"
}

display_passwords()
{
  set +x
  local k
  local v
  local s
  local vprefix
  local postfix
  local out_string
  local matchingvar
  local formattedprefix
  local -A subs
  subs[openshift]="OpenShift"
  subs[mcollective]="MCollective"
  subs[mongodb]="MongoDB"
  subs[activemq]="ActiveMQ"

  for k in "${!passwords[@]}"
  do
    out_string=
    matchingvar=
    for postfix in password password1 pass
    do
      vprefix="${k%$postfix}"
      [[ "$vprefix" != "$k" ]] && break
    done

    for v in "${vprefix}user" "${vprefix}user1"
    do
      if [[ -n "${!v+x}" ]]
      then
        matchingvar="$v"
        break
      fi
    done

    formattedprefix="${vprefix//_/ }"
    for s in "${!subs[@]}"
    do
      formattedprefix="${formattedprefix//${s}/${subs[$s]}}"
    done

    out_string+="$formattedprefix"
    [[ -n "$matchingvar" ]] && out_string+="${matchingvar##*_}: ${!matchingvar} "
    [[ "$vprefix" != "$k" ]] && out_string+="${k##*_}"
    out_string+=": ${!k}"
    echo "$out_string"
  done
  set -x
}

configure_repos()
{
  echo 'OpenShift: Begin configuring repos.'
  # Determine which channels we need and define corresponding predicate
  # functions.

  # Make need_${repo}_repo return false by default.
  local repo
  for repo in optional infra node client_tools extra \
              fuse_cartridge amq_cartridge jbosseap_cartridge jbosseap jbossews
  do eval "need_${repo}_repo() { false; }"
  done

  is_true "$enable_optional_repo" && need_optional_repo() { :; }

  if [[ -n "${jbossews_extra_repo}${jbosseap_extra_repo}${rhel_optional_repo}${rhscl_extra_repo}${fuse_extra_repo}${amq_extra_repo}" ]]
  then need_extra_repo() { :; }
  fi

  if activemq || broker || datastore || named || router
  then
    # The ose-infrastructure channel has the activemq, broker, and mongodb
    # packages.  The ose-infrastructure and ose-node channels also include
    # the yum-plugin-priorities package, which is needed for the installation
    # script itself, so we require ose-infrastructure here even if we are
    # only installing named.
    need_infra_repo() { :; }

    # The rhscl channel is needed for the ruby193 software collection.
    need_rhscl_repo() { :; }
  fi

  # Bug 1054405 Currently oo-admin-yum-validator enables the client tools repo
  # whenever the broker role is selected (even if the goal is only to install
  # support infrastructure like activemq).  Until that is fixed we must always
  # install the client tools repo along with the infrastructure repo.
  need_infra_repo && need_client_tools_repo() { :; }

  if node
  then
    # The ose-node channel has node packages including all the cartridges.
    need_node_repo() { :; }

    # The jbosseap and jbossas cartridges require the jbossas packages
    # in the jbappplatform channel.
    is_true "$need_jbosseap" \
             && need_jbosseap_cartridge_repo() { :; } \
             && need_jbosseap_repo() { :; }

    # The jbossews cartridge requires the tomcat packages in the jb-ews channel.
    is_true "$need_jbossews" && need_jbossews_repo() { :; }

    # The fuse/amq cartridges require their own channels.
    is_true "$need_fuse" && need_fuse_cartridge_repo() { :; }
    is_true "$need_amq" && need_amq_cartridge_repo() { :; }

    # The rhscl channel is needed for several cartridge platforms.
    need_rhscl_repo() { :; }
  fi

  # The configure_yum_repos, configure_rhn_channels, and
  # configure_rhsm_channels functions will use the need_${repo}_repo
  # predicate functions define above.
  case "$install_method" in
    (yum)
      configure_yum_repos
      ;;
    (rhn)
      configure_rhn_channels
      ;;
    (rhsm)
      configure_rhsm_channels
      ;;
  esac

  echo 'OpenShift: Completed configuring repos.'
}

configure_yum_repos()
{
  configure_rhel_repo
  need_optional_repo && configure_optional_repo
  need_rhscl_repo && configure_rhscl_repo
  configure_ose_yum_repos
  configure_cart_repos
  configure_extra_repos
  yum clean metadata
  yum_install_or_exit openshift-enterprise-release
}

# Define plain Yum repos if the parameters are given.
# This can be useful even if the main subscription is via RHN.
configure_ose_yum_repos()
{
  local repo
  for repo in infra node jbosseap_cartridge client_tools
  do
    if [[ -n "$ose_repo_base" ]]
    then
      local layout=puddle; [[ -n "$cdn_layout" ]] && layout=cdn
      "need_${repo}_repo" && def_ose_yum_repo "$ose_repo_base" "$layout" "$repo"
    fi
    if [[ -n "$ose_extra_repo_base" ]]
    then
      "need_${repo}_repo" && def_ose_yum_repo "$ose_extra_repo_base" 'extra' "$repo"
    fi
  done

  return 0
}

configure_rhel_repo()
{
  # In order for the %post section to succeed, it must have a way of
  # installing from RHEL. The post section cannot access the method that
  # was used in the base install. This configures a RHEL yum repo which
  # you must supply.
if [[ -n "$rhel_repo" ]]
then
  cat > '/etc/yum.repos.d/rhel.repo' <<YUM
[rhel6]
name=RHEL 6 base OS
baseurl=$rhel_repo
enabled=1
gpgcheck=0
priority=20
sslverify=false
exclude=tomcat6* $yum_exclude_pkgs

YUM
fi
}

configure_optional_repo()
{
if [[ -n "$rhel_optional_repo" ]]
then
  cat > '/etc/yum.repos.d/rheloptional.repo' <<YUM
[rhel6_optional]
name=RHEL 6 Optional
baseurl=$rhel_optional_repo
enabled=1
gpgcheck=0
priority=20
sslverify=false
exclude= $yum_exclude_pkgs

YUM
fi
}

def_ose_yum_repo()
{
  local repo_base="$1"
  local layout="$2"  # one of: puddle, extra, cdn
  local channel="$3" # one of: client_tools, infra, node, jbosseap_cartridge

  local -A map
  local url
  case "$layout" in
  puddle | extra)
    map=([client_tools]=RHOSE-CLIENT-2.2 [infra]=RHOSE-INFRA-2.2 [node]=RHOSE-NODE-2.2 [jbosseap_cartridge]=RHOSE-JBOSSEAP-2.2)
    url="${repo_base}/${map[$channel]}/x86_64/os/"
    ;;
  cdn | * )
    map=([client_tools]=ose-rhc [infra]=ose-infra [node]=ose-node [jbosseap_cartridge]=ose-jbosseap)
    url="${repo_base}/${map[$channel]}/2.2/os"
    ;;
  esac
  cat > "/etc/yum.repos.d/openshift-${channel}-${layout}.repo" <<YUM
[openshift_${channel}_${layout}]
name=OpenShift $channel $layout
baseurl=$url
enabled=1
gpgcheck=0
priority=10
sslverify=false
exclude= $yum_exclude_pkgs

YUM
}

configure_rhscl_repo()
{
  if [[ -n "$rhscl_repo_base" ]]
  then
    cat <<YUM > '/etc/yum.repos.d/rhscl.repo'
[rhscl]
name=rhscl
baseurl=${rhscl_repo_base}/rhscl/1/os/
enabled=1
priority=10
gpgcheck=0
exclude= $yum_exclude_pkgs

YUM

  fi
}

# Add any Yum repositories that are needed for cartridges or their dependencies.
configure_cart_repos()
{
  local -A url=(
          [jbosseap]="${jboss_repo_base}/jbeap/${jbosseap_version}/os"
          [jbossews]="${jboss_repo_base}/jbews/2/os"
    [fuse_cartridge]="${jboss_repo_base}/ose-jbossfuse/2.2/os"
     [amq_cartridge]="${jboss_repo_base}/ose-jbossamq/2.2/os"
  )
  # Using jboss_repo_base for amq/fuse might seem a little odd in the future;
  # in which case, add a repo base just for them. Use extras if needed for now.

  local repo
  for repo in "${!url[@]}"
  do
    "need_${repo}_repo" || continue
    cat <<YUM > "/etc/yum.repos.d/${repo}.repo"
[${repo}]
name=$repo
baseurl=${url[$repo]}
enabled=1
gpgcheck=0
priority=30
sslverify=false
exclude= $yum_exclude_pkgs

YUM
  done
}

# Add all defined extra repos in one file.
configure_extra_repos()
{
  local extra_repo_file='/etc/yum.repos.d/ose_extra.repo'
  if [[ -e "$extra_repo_file" ]]
  then
      > "$extra_repo_file"
  fi

  local -A priority=(
    [rhscl_extra_repo]=10
    [rhel_extra_repo]=20
    [jbosseap_extra_repo]=30
    [jbossews_extra_repo]=30
    [fuse_extra_repo]=30
    [amq_extra_repo]=30
  )
  local -A exclude=(
    [rhel_extra_repo]='tomcat6*'
  )

  local repo
  for repo in "${!priority[@]}"
  do
    local url="${!repo}"
    if [[ -n "$url" ]]
    then
      cat <<YUM >> "$extra_repo_file"
[${repo}]
name=$repo
baseurl=$url
enabled=1
gpgcheck=0
priority=${priority[$repo]}
sslverify=false
exclude=${exclude[$repo]-} $yum_exclude_pkgs

YUM
    fi
  done
}

configure_subscription()
{
   configure_ose_yum_repos # if requested
   need_extra_repo && configure_extra_repos
   # install our tool to enable repo/channel configuration
   yum_install_or_exit openshift-enterprise-yum-validator

   local roles=  # we will build the list of roles we need, then enable them.
   need_infra_repo && roles="$roles --role broker"
   need_client_tools_repo && roles="$roles --role client"
   need_node_repo && roles="$roles --role node"
   need_jbosseap_cartridge_repo && roles="$roles --role $jbosseap_yumvalidator_role"
   need_fuse_cartridge_repo && roles="$roles --role node-fuse"
   need_amq_cartridge_repo && roles="$roles --role node-amq"
   # We want word-splitting on $roles.
   oo-admin-yum-validator -o 2.2 --fix-all $roles || : # when fixing, rc is always false
   oo-admin-yum-validator -o 2.2 $roles || abort_install # so check when fixes are done

   # Normally we could just install o-e-release and it would pull in yum-validator;
   # however it turns out the ruby dependencies can sometimes be pulled in from the
   # wrong channel before yum-validator does its work. So, install it afterward.
   yum_install_or_exit openshift-enterprise-release
   configure_ose_yum_repos # refresh if overwritten by validator
   need_extra_repo && configure_extra_repos

   return 0
}

configure_rhn_channels()
{
  if [[ -n "$rhn_reg_actkey" ]]
  then
    echo 'OpenShift: Register to RHN Classic using an activation key'
    # We want word-splitting on $rhn_reg_opts.
    rhnreg_ks --force "--activationkey=$rhn_reg_actkey" "--profilename=$rhn_profile_name" $rhn_reg_opts || abort_install
  else
    if [[ -n "$rhn_creds_provided" ]]
    then
      # Don't log password.
      set +x
      echo 'OpenShift: Register to RHN Classic with username and password'
      echo "rhnreg_ks --force \"--profilename=$rhn_profile_name\" --username \"${rhn_user}\" $rhn_reg_opts"
      rhnreg_ks --force "--profilename=$rhn_profile_name" --username "$rhn_user" --password "$rhn_pass" $rhn_reg_opts || abort_install
      set -x
    else
      echo 'OpenShift: No credentials given for RHN Classic; assuming already configured'
    fi
  fi

  if [[ -n "$rhn_creds_provided" ]]
  then
    # Enable the node or infrastructure channel to enable installing the release
    # RPM.
    local -a repos=('rhel-x86_64-server-6-rhscl-1')
    if ! need_node_repo || need_infra_repo
    then repos+=('rhel-x86_64-server-6-ose-2.2-infrastructure')
    fi
    need_node_repo && repos+=('rhel-x86_64-server-6-ose-2.2-node' 'jb-ews-2-x86_64-server-6-rpm')
    need_client_tools_repo && repos+=('rhel-x86_64-server-6-ose-2.2-rhc')
    need_jbosseap_cartridge_repo && repos+=('rhel-x86_64-server-6-ose-2.2-jbosseap' "jbappplatform-${jbosseap_version}-x86_64-server-6-rpm")
    need_fuse_cartridge_repo && repos+=('rhel-x86_64-server-6-ose-2.2-jbossfuse')
    need_amq_cartridge_repo && repos+=('rhel-x86_64-server-6-ose-2.2-jbossamq')

    # Don't log password.
    set +x
    local repo
    for repo in "${repos[@]}"
    do [[ "$(rhn-channel -l)" = *"$repo"* ]] || rhn-channel --add --channel "$repo" --user "$rhn_user" --password "$rhn_pass" || abort_install
    done
    set -x
  fi

  configure_subscription
}

configure_rhsm_channels()
{
  if [[ -n "$rhn_creds_provided" ]]
  then
    # Don't log password.
    set +x
    echo 'OpenShift: Register with RHSM'
    echo "subscription-manager register --force \"--username=${rhn_user}\" --name \"${rhn_profile_name}\" $rhn_reg_opts"
    subscription-manager register --force "--username=$rhn_user" "--password=$rhn_pass" --name "$rhn_profile_name" $rhn_reg_opts || abort_install
    set -x
  else
    echo 'OpenShift: No credentials given for RHSM; assuming already configured'
  fi

  if [[ -n "$sm_reg_pool" ]]
  then
    echo 'OpenShift: Removing all current subscriptions'
    subscription-manager remove --all
  else
    echo 'OpenShift: No pool ids were given, so none are being registered'
  fi

  # If CONF_SM_REG_POOL was not specified, this for loop is a no-op.
  local poolid
  for poolid in ${sm_reg_pool//[, :+\/-]/ }
  do
    echo "OpenShift: Registering subscription from pool id $poolid"
    subscription-manager attach --pool "$poolid" || abort_install
  done

  # Enable the node or infrastructure repo to enable installing the release RPM
  if need_node_repo
  then subscription-manager repos '--enable=rhel-6-server-ose-2.2-node-rpms' || abort_install
  else subscription-manager repos '--enable=rhel-6-server-ose-2.2-infra-rpms' || abort_install
  fi
  configure_subscription
}

abort_install()
{
  [[ "$#" -ge 1 ]] && echo "$*"
  # Don't change this; it is used as an automation cue.
  echo 'OpenShift: Aborting Installation.'
  exit 1
}

yum_install_or_exit()
{
  echo "OpenShift: yum install $*"
  local count=0
  time while true
  do
    yum install -y "$@" $disable_plugin && return
    if [[ "$count" -gt 3 ]]
    then
      echo "OpenShift: Command failed: yum install $*"
      echo 'OpenShift: Please ensure relevant repos/subscriptions are configured.'
      abort_install
    fi
    let count+=1
  done
}

# Install the client tools.
install_rhc_pkg()
{
  yum_install_or_exit rhc
}

# Install the router (nginx).
install_router_pkgs()
{
  case "$router" in
    (f5)
      # Nothing to do; setting up an F5 instance is outside the scope of this
      # script.
      ;;
    (nginx)
      yum_install_or_exit nginx16-nginx rubygem-openshift-origin-routing-daemon
      ;;
  esac
}

# Set up the system express.conf so our broker will be used by default.
configure_rhc()
{
  # set_conf expects there to be a newline character on the last line.
  echo >> '/etc/openshift/express.conf'

  # Set up the system express.conf so this broker will be used by default.
  set_conf '/etc/openshift/express.conf' libra_server "'${broker_hostname}'"
}

# Configure the host to use an HTTP or HTTPS proxy for outgoing connections
# so that Git and cartridge-specific packaging tools work properly.
configure_outgoing_http_proxy()
{
  [[ -n "$outgoing_http_proxy" || -n "$outgoing_https_proxy" ]] || return 0

  if node
  then
    # These environment variables should suffice for PERL's cpanm, PHP's
    # PEAR, Python's easy_install, and Ruby's rubygems.
    echo "localhost,127.*,*.$domain" > '/etc/openshift/env/no_proxy'
    # Note that CPAN requires a proper URL, including schema.
    if [[ -n "$outgoing_http_proxy" ]]
    then
      http_proxy_url="$outgoing_http_proxy"
      if ! [[ "$http_proxy_url" =~ ^https?://* ]]
      then http_proxy_url="http://$http_proxy_url"
      fi
      echo "$http_proxy_url" > '/etc/openshift/env/http_proxy'
    fi
    if [[ -n "$outgoing_https_proxy" ]]
    then
      https_proxy_url="$outgoing_https_proxy"
      if ! [[ "$https_proxy_url" =~ ^https?://* ]]
      then https_proxy_url="https://$https_proxy_url"
      fi
      echo "$https_proxy_url" > '/etc/openshift/env/https_proxy'
    fi

    # Configure NodeJS NPM to use the proxy.
    mkdir -p '/etc/openshift/skel'
    printf '%s\n' \
      "proxy = $outgoing_http_proxy" \
      "https-proxy = $outgoing_https_proxy" \
      > '/etc/openshift/skel/.npmrc'

    # Configure Maven for JBoss.
    # So far we only need to parse the URL for Maven, but it could be moved
    # earlier in this function if future additions to this function have some
    # use for the URL components.
    local http_proxy_auth https_proxy_auth \
          http_proxy_user http_proxy_pass https_proxy_user https_proxy_pass \
          http_proxy_host_port https_proxy_host_port \
          http_proxy_hostname https_proxy_hostname \
          http_proxy_port https_proxy_port \

    # Strip any leading schemas (schema is inferred from the variable's name).
    http_proxy_auth="${outgoing_http_proxy#*//}"
    https_proxy_auth="${outgoing_https_proxy#*//}"

    # Split on '@' into (possibly) authentication credentials and the rest.
    read http_proxy_auth http_proxy_host_port <<< "${http_proxy_auth//@/ }"
    read https_proxy_auth https_proxy_host_port <<< "${https_proxy_auth//@/ }"

    if [[ -z "$http_proxy_host_port" ]]
    then # No credentials were specified.
      http_proxy_host_port="$http_proxy_auth"
      http_proxy_auth=
    else
      read http_proxy_user http_proxy_pass <<< "${http_proxy_auth//:/ }"
    fi

    if [[ -z "$https_proxy_host_port" ]]
    then # No credentials were specified.
      https_proxy_host_port="$https_proxy_auth"
      https_proxy_auth=
    else
      read https_proxy_user https_proxy_pass <<< "${https_proxy_auth//:/ }"
    fi

    # Strip any trailing slashes (and possibly more, but there shouldn't be
    # anything more).
    http_proxy_host_port="${http_proxy_host_port%/*}"
    https_proxy_host_port="${https_proxy_host_port%/*}"

    # Split on ':' into hostname and (possibly) port parts.
    read http_proxy_hostname http_proxy_port <<< "${http_proxy_host_port//:/ }"
    read https_proxy_hostname https_proxy_port <<< "${https_proxy_host_port//:/ }"

    local proxies_stanza="\
<settings>
  <proxies>
    ${outgoing_http_proxy:+<proxy>
      <active>true</active>
      <protocol>http</protocol>
      <host>${http_proxy_hostname}</host>
      ${http_proxy_port:+<port>${http_proxy_port}</port>}
      ${http_proxy_user:+<username>${http_proxy_user}</username>}
      ${http_proxy_pass:+<password>${http_proxy_pass}</password>}
      <nonProxyHosts>localhost|${domain}</nonProxyHosts>
    </proxy>
    }
    ${outgoing_https_proxy:+<proxy>
      <active>true</active>
      <protocol>https</protocol>
      <host>${https_proxy_hostname}</host>
      ${https_proxy_port:+<port>${https_proxy_port}</port>}
      ${https_proxy_user:+<username>${https_proxy_user}</username>}
      ${https_proxy_pass:+<password>${https_proxy_pass}</password>}
      <nonProxyHosts>localhost|${domain}</nonProxyHosts>
    </proxy>
}  </proxies>
</settings>"
    # Delete blank lines (this is the slowest part of this function--maybe use
    # an external tool instead?).
    shopt -s extglob # for *()
    proxies_stanza="${proxies_stanza//$'\n'*([[:space:]])$'\n'/$'\n'}"
    shopt -u extglob
    mkdir -p '/etc/openshift/skel/.m2'
    local settings_xml='/etc/openshift/skel/.m2/settings.xml'
    if ! [[ -e "$settings_xml" ]] || ! grep -q '<proxies>' "$settings_xml"
    then
      echo "$proxies_stanza" >> "$settings_xml"
    else
      # Escape newlines in $proxies_stanza so that we can use it in a sed
      # expression.
      proxies_stanza="${proxies_stanza//$'\n'/\\$'\n'}"
      sed -i -e "/<proxies>/,/<\/proxies>/c$proxies_stanza" "$settings_xml"
    fi
  fi

  # Configure Git so that downloadable cartridges can work.
  cat <<EOF > '/etc/gitconfig'
[http]
      proxy = $outgoing_https_proxy
[https]
      proxy = $outgoing_https_proxy

# git-clone seems to hang with HTTP over a Squid proxy where HTTPS works fine.
[url "https://"]
        insteadOf = http://

[http "localhost"]
      proxy =
[http "${domain}"]
      proxy =
EOF

  # Configure the broker to use the proxy for downloadable cartridges.
  # Note: There is only one setting in /etc/openshift/broker.conf, HTTP_PROXY,
  # which the broker uses for both HTTP and HTTPS connetions.  Usually, one will
  # use an https: URL for downloadable cartridges, so we put that here.
  broker && set_broker HTTP_PROXY "$outgoing_https_proxy"

  return 0
}

# Install broker-specific packages.
install_broker_pkgs()
{
  local pkgs='openshift-origin-broker'
  pkgs="$pkgs openshift-origin-broker-util"
  pkgs="$pkgs rubygem-openshift-origin-msg-broker-mcollective"
  pkgs="$pkgs ruby193-mcollective-client"
  pkgs="$pkgs rubygem-openshift-origin-auth-remote-user"
  pkgs="$pkgs rubygem-openshift-origin-dns-nsupdate"
  pkgs="$pkgs openshift-origin-console"
  pkgs="$pkgs rubygem-openshift-origin-admin-console"
  is_true "$enable_routing_plugin" && pkgs="$pkgs rubygem-openshift-origin-routing-activemq"
  [[ "$router" = f5 ]] && pkgs="$pkgs rubygem-openshift-origin-routing-daemon"

  # We use semanage in configure_selinux_policy_on_broker, so we need to
  # install policycoreutils-python.
  pkgs="$pkgs policycoreutils-python"

  # We want word-splitting on $pkgs.
  yum_install_or_exit $pkgs
}

# Install node-specific packages.
install_node_pkgs()
{
  local pkgs='rubygem-openshift-origin-node ruby193-rubygem-passenger-native'
  pkgs="$pkgs openshift-origin-node-util"
  pkgs="$pkgs ruby193-mcollective openshift-origin-msg-node-mcollective"

  # We use semanage in configure_selinux_policy_on_node, so we need to
  # install policycoreutils-python.
  pkgs="$pkgs policycoreutils-python"

  pkgs="$pkgs rubygem-openshift-origin-container-selinux"
  pkgs="$pkgs rubygem-openshift-origin-frontend-nodejs-websocket"
  pkgs="$pkgs rubygem-openshift-origin-frontend-haproxy-sni-proxy"

  if [[ "$log_to_syslog" = *gears* ]]
  then
    if rpm -q rsyslog
    then
      # RHEL 6.6's rsyslog7 package conflicts with the earlier RHEL 6 package.
      yum shell --disableplugin=priorities -y <<YUM
erase rsyslog
install rsyslog7 rsyslog7-mmopenshift
transaction run
YUM
    fi
  fi

  case "$node_apache_frontend" in
    mod_rewrite)
      pkgs="$pkgs rubygem-openshift-origin-frontend-apache-mod-rewrite"
      ;;
    vhost)
      pkgs="$pkgs rubygem-openshift-origin-frontend-apache-vhost"
      ;;
    *)
      echo "Invalid value: CONF_NODE_APACHE_FRONTEND=$node_apache_frontend"
      abort_install
      ;;
  esac

  # We want word-splitting on $pkgs.
  yum_install_or_exit $pkgs
}

# Remove abrt-addon-python if necessary
# https://bugzilla.redhat.com/show_bug.cgi?id=907449
# This only affects the python v2 cart
remove_abrt_addon_python()
{
  if grep 'Enterprise Linux Server release 6.4' '/etc/redhat-release' && rpm -q abrt-addon-python && rpm -q openshift-origin-cartridge-python
  then yum $disable_plugin remove -y abrt-addon-python || abort_install
  fi
}

# Parse the list of cartridges that the user has specified should be
# installed in order to derive the list of packages that we must install
# as well as to determine whether or not we will need JBoss
# subscriptions.
#
# The following variable is used:
#
#   cartridges - comma-delimited list of cartridges to install; should
#     be set by set_defaults (see also CONF_CARTRIDGES / cartridges).
#
# The following variables will be assigned:
#
#   install_cart_pkgs - space-delimited string of packages to install; intended to be
#     used by install_cartridges.
#   (the following are intended to be used by configure_repos:)
#   need_jbosseap - Boolean value indicating whether JBossEAP will be installed
#   need_jbossews - Boolean value indicating whether JBossEWS will be installed
#   need_fuse     - Boolean value indicating whether Fuse will be installed
#   need_amq      - Boolean value indicating whether AM-Q will be installed
parse_cartridges()
{
  # $p maps a cartridge specification to a comma-delimited list a packages.
  local -A premium=(
    [amq]=openshift-origin-cartridge-amq
    [fuse]=openshift-origin-cartridge-fuse
    [fuse-builder]=openshift-origin-cartridge-fuse-builder
    [jbosseap]=openshift-origin-cartridge-jbosseap
  )
  local -A stdframework=(
    [diy]=openshift-origin-cartridge-diy
    [haproxy]=openshift-origin-cartridge-haproxy
    [jbossews]=openshift-origin-cartridge-jbossews
    [nodejs]=openshift-origin-cartridge-nodejs
    [perl]=openshift-origin-cartridge-perl
    [php]=openshift-origin-cartridge-php
    [python]=openshift-origin-cartridge-python
    [ruby]=openshift-origin-cartridge-ruby
  )
  local -A stdaddon=(
    [cron]=openshift-origin-cartridge-cron
    [jenkins]='openshift-origin-cartridge-jenkins-client openshift-origin-cartridge-jenkins'
    [mongodb]=openshift-origin-cartridge-mongodb
    [mysql]=openshift-origin-cartridge-mysql
    [postgresql]=openshift-origin-cartridge-postgresql
  )
  local -A p=( )
  local k
  for k in "${!premium[@]}"     ; do p[$k]="${premium[$k]}"; done
  for k in "${!stdframework[@]}"; do p[$k]="${stdframework[$k]}"; done
  for k in "${!stdaddon[@]}"    ; do p[$k]="${stdaddon[$k]}"; done

  # for those with optional/recommended dependencies
  local -a meta=(
    jbossas
    jbosseap
    jbossews
    nodejs
    perl
    php
    python
    ruby
  )

  # Save the list of all packages before we add mappings that will
  # introduce duplicates into the range of p.
  local -a all=( ${p[@]} )

  # Set some package groups and aliases to provide shortcuts to the user.
  p[all]="${all[*]}"
  p[premium]="${premium[*]}"
  p[stdframework]="${stdframework[*]}"
  p[stdaddon]="${stdaddon[*]}"
  p[standard]="${stdframework[*]} ${stdaddon[*]}"
  p[jboss]="${p[jbossews]} ${p[jbosseap]}"
  p[postgres]="${p[postgresql]}"

  # Build the list of packages to install ($pkgs) based on the list of
  # cartridges that the user instructs us to install ($cartridges).  See
  # the documentation on the CONF_CARTRIDGES / cartridges options for
  # the rules governing how $cartridges will be passed.
  local -a pkgs=( )
  local pkg
  local cart_spec
  for cart_spec in ${cartridges//,/ }
  do
    if [[ "${cart_spec:0:1}" = - ]]
    then
      # Remove every package indicated by the cart_spec, or remove the package
      # with name equal to $cart_spec itself if the cart_spec does not map to
      # anything in $p.  This means we want word-splitting, so don't quote it.
      for pkg in ${p[${cart_spec:1}]:-${cart_spec:1}}
      do
        for k in "${!pkgs[@]}"
        do [[ "${pkgs[$k]}" = "$pkg" ]] && unset "pkgs[$k]"
        done
      done
    else
      # Append all packages indicated by the cart_spec, or append $cart_spec
      # itself if it does not map to anything in $p.  We want word-splitting
      # in case $cart_spec or ${p[$cart_spec]} maps to multiple cartridges, so
      # don't quote it.
      pkgs+=( ${p[$cart_spec]:-$cart_spec} )
    fi
  done

  if metapkgs_optional || metapkgs_recommended
  then
    local metapkg
    for metapkg in "${meta[@]}"
    do
      if [[ "${pkgs[@]}" =~ "-$metapkg" ]]
      then
        metapkgs_optional && pkgs+=( "openshift-origin-cartridge-dependencies-optional-$metapkg" )
        metapkgs_recommended && pkgs+=( "openshift-origin-cartridge-dependencies-recommended-$metapkg" )
      fi
    done
  fi

  # Set need_<cart>=1 if $pkgs includes the relevant cartridge,
  # need_<cart>=0 otherwise, so that configure_repos will enable
  # only the appropriate channels.
  need_jbosseap=0; [[ "${pkgs[*]}" = *"${p[jbosseap]}"* ]] && need_jbosseap=1
  need_jbossews=0; [[ "${pkgs[*]}" = *"${p[jbossews]}"* ]] && need_jbossews=1
    # fuse is "special" because there's also a fuse-builder cart that can be used with
    # either fuse or amq and doesn't necessarily imply either. It comes from either of
    # those two channels; assume if desired they will have one of those channels already.
  need_fuse=0;     [[ "${pkgs[*]}" =~ openshift-origin-cartridge-fuse( |$) ]] && need_fuse=1
  need_amq=0;      [[ "${pkgs[*]}" = *"${p[amq]}"* ]] && need_amq=1

  # Uniquify (and, as a side effect, sort) pkgs and assign the result to
  # install_cart_pkgs for install_cartridges to use.
  install_cart_pkgs="$( echo $(printf '%s\n' "${pkgs[@]}" | sort -u) )"
}

# Install any cartridges developers may want.
#
# The following variable is used:
#
#   install_cart_pkgs - space-delimited string of packages to install; should be set
#     by parse_cartridges.
install_cartridges()
{
  # When dependencies are missing, e.g. JBoss subscriptions,
  # still install as much as possible.
  #install_cart_pkgs="${install_cart_pkgs} --skip-broken"

  # We want word-splitting on $install_cart_pkgs.
  yum_install_or_exit $install_cart_pkgs
}

# Given the filename of a configuration file, the name of a setting,
# and a value, check whether the configuration file already assigns the
# given value to the setting.  If it does not, then comment out any
# existing setting and add the given setting.
#
# If the setting is found with the given value in the configuration file, then
# this function does not modify the file.  The search pattern used is
# /^\s*name\s*=\s*['"]?value\['"]?\s*(|#.*)$/.
#
# If the setting is found with a value other than the one specified, then the
# existing setting is commented out and the new setting is added after the old,
# with any short comment that is specified.  The added line will be in the form
# 'name=value' or, if a non-empty short comment is specified, 'name=value
# # short comment'.
#
# If the setting is not found in the file, then the new setting is appended to
# the end of the file, with any short and long comments that are specified.
# If a long comment is specified using the fifth and possibly subsequent
# arguments, then a blank line followed by '# long comment' (one line per
# argument) will be added before the line for the setting itself.
#
# Note that quotation marks are tolerated when checking whether the setting is
# already present, but are not added when adding the setting unless they are
# explicitly passed in as part of the value.
#
# $1 = configuration file's filename
# $2 = setting name
# $3 = value
# $4 = short comment (optional)
# $5- = long comment (optional)
set_conf()
{
  local file="$1" setting="$2" value="$3" shortcomment="${4-}"
  local newsetting="${setting}=${value//\//\\/}${shortcomment:+ #$shortcomment}"
  shift 4 || shift 3
  local longcomment=
  (( $# > 0 )) && printf -v longcomment '# %s\\\n' "$@"

  sed -i -e "
    :a
      # Check whether the setting already exists with the specified value.  If
      # it does, jump to :b.
      /^\\s*${setting}\\s*=\\s*['\"]\\?${value//\//\\/}['\"]\\?\\s*\\(\\|#.*\\)\$/bb

      # Check whether the setting already exists but with the a value other than
      # the specified one.  If it does, then comment out the old setting, add
      # a new setting with the specified value after the old setting, and jump
      # to :b.
      s/^\\(\\s*\\)#\\?\\(\\s*${setting}\\s*=[^\\n]*\\)/\\1#\\2\\n${newsetting}/;tb

      # Neither of the previous two checks were positive, so check whether we
      # have reached the end of the file, and if so, append the new setting
      # along with any long comment that has been specified.
      \$a \\
${longcomment:+\\
$longcomment}$newsetting

      # Loop and repeat the above checks.
      n
      ba
    :b
      # Loop until the end of the file, without modifying the stream.
      n
      bb
    " "$file"
}

set_mongodb() { set_conf /etc/mongodb.conf "$@"; }
set_broker() { set_conf /etc/openshift/broker.conf "$@"; }
set_console() { set_conf /etc/openshift/console.conf "$@"; }
set_node() { set_conf /etc/openshift/node.conf "$@"; }
set_routing_daemon() { set_conf /etc/openshift/routing-daemon.conf "$@"; }

# Fix up SELinux policy on the broker.
configure_selinux_policy_on_broker()
{
  # We combine these setsebool commands into a single semanage command
  # because separate commands take a long time to run.
  time (
    # Allow console application to access executable and writable memory
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

  fixfiles -R ruby193-rubygem-passenger restore
  fixfiles -R ruby193-mod_passenger restore

  restorecon -rv '/var/run'
  # This should cover everything in the SCL, including passenger
  time restorecon -rv '/opt'
}

# Fix up SELinux policy on the node.
configure_selinux_policy_on_node()
{
  # We combine these setsebool commands into a single semanage command
  # because separate commands take a long time to run.
  ulimit -n 131071  # semanage runs out of file descriptors at normal ulimit
  time (
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

    # Enable rules to keep gears from binding where they should not
    # Note: relies on node code loading, must load after node.conf has correct frontend configured
    is_true "$isolate_gears" && oo-gear-firewall -s output -b "$district_first_uid" -e "$district_last_uid"
  ) | semanage -i -


  restorecon -rv '/var/run'
  time restorecon -rv '/var/lib/openshift' '/etc/httpd/conf.d/openshift'
  # disallow gear users from seeing what other gears exist
  chmod 0751 '/var/lib/openshift'
}

configure_pam_on_node()
{
  sed -i -e 's|pam_selinux|pam_openshift|g' '/etc/pam.d/sshd'

  local t
  local f
  for f in runuser runuser-l sshd su system-auth-ac
  do
    t="/etc/pam.d/$f"
    if ! grep -q 'pam_namespace.so' "$t"
    then
      # We add two rules.  The first checks whether the user's shell is
      # /usr/bin/oo-trap-user, which indicates that this is a gear user,
      # and skips the second rule if it is not.
      echo -e 'session\t\t[default=1 success=ignore]\tpam_succeed_if.so quiet shell = /usr/bin/oo-trap-user' >> "$t"

      # The second rule enables polyinstantiation so that the user gets
      # private /tmp and /dev/shm directories.
      echo -e 'session\t\trequired\tpam_namespace.so no_unmount_on_close' >> "$t"
    fi
  done

  # Configure the pam_namespace module to polyinstantiate the /tmp and
  # /dev/shm directories.  Above, we only enable pam_namespace for
  # OpenShift users, but to be safe, blacklist the root and adm users
  # to be sure we don't polyinstantiate their directories.
  echo '/tmp        $HOME/.tmp/      user:iscript=/usr/sbin/oo-namespace-init root,adm' > '/etc/security/namespace.d/tmp.conf'
  echo '/dev/shm  tmpfs  tmpfs:mntopts=size=5M:iscript=/usr/sbin/oo-namespace-init root,adm' > '/etc/security/namespace.d/shm.conf'
}

configure_cgroups_on_node()
{
  local t
  local f
  for f in runuser runuser-l sshd system-auth-ac
  do
    t="/etc/pam.d/$f"
    if ! grep -q 'pam_cgroup' "$t"
    then
      echo -e 'session\t\toptional\tpam_cgroup.so' >> "$t"
    fi
  done

  cp -vf /opt/rh/ruby193/root/usr/share/gems/doc/openshift-origin-node-*/cgconfig.conf '/etc/cgconfig.conf'
  restorecon -rv '/etc/cgconfig.conf'
  mkdir -p '/cgroup'
  restorecon -rv '/cgroup'
  chkconfig cgconfig on
  chkconfig cgred on
}

configure_quotas_on_node()
{
  # Get the mountpoint for /var/lib/openshift (should be /).
  local geardata_mnt=$(df -P '/var/lib/openshift' 2>/dev/null | tail -n 1 | awk '{ print $6 }')

  if [[ -z "$geardata_mnt" ]]
  then
    echo 'Could not enable quotas for gear data: unable to determine mountpoint.'
  else
    # Enable user quotas for the filesystem housing /var/lib/openshift.
    sed -i -e "/^[^[:blank:]]\\+[[:blank:]]\\+${geardata_mnt////\/}[[:blank:]]/{/usrquota/! s/[[:blank:]]\\+/,usrquota&/4;}" '/etc/fstab'
    # Remount to enable quotas immediately.
    mount -o remount "$geardata_mnt"

    # External mounts, esp. at /var/lib/openshift, may often be created
    # with an incorrect context and quotacheck hits SElinux denials.
    time restorecon "$geardata_mnt"

    # quotacheck fails if quotas are enabled.
    quotaoff "$geardata_mnt"

    # Generate user quota info for the mount point.
    time quotacheck -cmug "$geardata_mnt"

    # Fix the SELinux label of the created quota file.
    restorecon "${geardata_mnt}/aquota.user"

    # (Re)enable quotas.
    time quotaon "$geardata_mnt"
  fi
}

configure_idler_on_node()
{
  [[ "$idle_interval" =~ ^[[:digit:]]+$ ]] || return 0
  cat <<CRON > '/etc/cron.hourly/auto-idler'
(
  /usr/sbin/oo-last-access
  /usr/sbin/oo-auto-idler idle --interval "$idle_interval"
) >> '/var/log/openshift/node/auto-idler.log' 2>&1
CRON
  chmod +x '/etc/cron.hourly/auto-idler'
}

# $1 = setting name
# $2 = value
# $3 = long comment
set_sysctl()
{
  set_conf '/etc/sysctl.conf' "$1" "$2" '' "$3"
}

# Turn some sysctl knobs.
configure_sysctl_on_node()
{
  set_sysctl 'kernel.sem' '250  32000 32  4096' 'Accomodate many httpd instances for OpenShift gears.'

  set_sysctl 'net.ipv4.ip_local_port_range' '15000 35530' 'Move the ephemeral port range to accomodate the OpenShift port proxy.'

  set_sysctl 'net.netfilter.nf_conntrack_max' 1048576 'Increase the connection tracking table size for the OpenShift port proxy.'

  set_sysctl 'net.ipv4.ip_forward' 1 'Enable forwarding for the OpenShift port proxy.'

  set_sysctl 'net.ipv4.conf.all.route_localnet' 1 'Allow the OpenShift port proxy to route using loopback addresses.'

  # As recommended elsewhere and investigated at length in https://bugzilla.redhat.com/show_bug.cgi?id=1085115
  # this is a safe, effective way to keep lots of short requests from exhausting the connection table.
  set_sysctl 'net.ipv4.tcp_tw_reuse' 1 'Reuse closed connections quickly.'
}


configure_sshd_on_node()
{
  # Configure sshd to pass the GIT_SSH environment variable through.
  # The newline is needed because cloud-init doesn't add a newline after the
  # configuration it adds.
  printf '\nAcceptEnv GIT_SSH\n' >> '/etc/ssh/sshd_config'

  # Up the limits on the number of connections to a given node.
  sed -i -e 's/^#MaxSessions .*$/MaxSessions 40/' '/etc/ssh/sshd_config'
  sed -i -e 's/^#MaxStartups .*$/MaxStartups 40/' '/etc/ssh/sshd_config'

  RESTART_NEEDED=true
}

install_datastore_pkgs()
{
  yum_install_or_exit mongodb-server mongodb
}

# The init script lies to us as of version 2.0.2-1.el6_3: The start
# and restart actions return before the daemon is ready to accept
# connections (appears to take time to initialize the journal). Thus
# we need the following to wait until the daemon is really ready.
wait_for_mongod()
{
  echo "OpenShift: Waiting for MongoDB to start ($(date +%H:%M:%S))..."
  while :
  do
    echo exit | mongo && break
    sleep 5
  done
  echo "OpenShift: MongoDB is ready! ($(date +%H:%M:%S))"
}

# $1 = commands
# $2 = regex to test output (optional)
# $3 = user (optional)
# $4 = password (optional)
execute_mongodb()
{
  echo 'Running commands on MongoDB:'
  echo '---'
  echo "$1"
  echo '---'

  local userpass=
  if [[ -n "${3+x}" && -n "${4+x}" ]]
  then userpass="-u $3 -p $4 admin"
  fi

  # We want word-splitting on $userpass.
  local output="$( echo "$1" | mongo $userpass )"
  echo "$output"
  if [[ -n "${2+x}" ]]
  then # test output against regex
    [[ "$output" =~ $2 ]] || return 1
  fi
  return 0
}

# This configuration step should only be performed if MongoDB is not
# replicated or if this host is the primary in a replicated setup.
configure_datastore_add_users()
{
  set +x  # just confusing to have everything re-echo
  wait_for_mongod

  time execute_mongodb "$(
    if [[ "$datastore_replicants" =~ , ]]
    then
      echo 'while (rs.isMaster().primary == null) { sleep(5); }'
    fi
    if is_true "$enable_datastore_auth"
    then
      # Add an administrative user.
      echo 'use admin'
      echo "db.addUser('${mongodb_admin_user}', '${mongodb_admin_password}')"
      echo "db.auth('${mongodb_admin_user}', '${mongodb_admin_password}')"
    fi

    # Add the user that the broker will use.
    echo "use $mongodb_name"
    echo "db.addUser('${mongodb_broker_user}', '${mongodb_broker_password}')"
  )"
  set -x

  PASSWORDS_TO_DISPLAY=true
}

# This configuration step should only be performed on the primary in
# a replicated setup, and only after the secondary DBs are installed.
configure_datastore_add_replicants()
{
  set +x  # just confusing to have everything re-echo
  wait_for_mongod

  # initiate the replica set with just this host
  time execute_mongodb 'rs.initiate()' '"ok" : 1' ||
    abort_install 'OpenShift: Failed to form MongoDB replica set; please do this manually.'

  local master_out="$(echo 'while (rs.isMaster().primary == null) { sleep(5); }; print("host="+rs.isMaster().primary)' | mongo | grep 'host=')" ||
    abort_install 'OpenShift: Failed to query the MongoDB replica set master; please verify the replica set configuration manually.'

  configure_datastore_add_users

  # Configure the replica set.
  local i
  local replicant
  for replicant in ${datastore_replicants//,/ }
  do
    if [[ "$replicant" != "${master_out#host=}" ]]
    then
      # Verify connectivity to $replicant before attempting to add it to the
      # replica set.  We can simply attempt to use the mongo shell to connect:
      # even if we don't authenticate, it appears to return a 0 exit code on
      # successful connect.
      for i in {1..10}
      do
        echo "Attempting to connect to ${replicant}..."
        if echo | mongo "$replicant"
        then
          break
        fi
        sleep 60
      done

      time execute_mongodb "rs.add(\"${replicant}\")" '"ok" : 1' "$mongodb_admin_user" "$mongodb_admin_password" ||
        abort_install "OpenShift: Failed to add $replicant to replica set; please verify the replica set manually"
    fi
  done

  set -x
}

configure_datastore()
{
  # Require authentication.
  set_mongodb auth true

  # Workaround for oo-accept-broker, which performs a strict pattern match for
  # 'auth = true' (with spaces).
  sed -i -e 's/auth=true/auth = true/' '/etc/mongodb.conf'

  # Use a smaller default size for databases.
  set_mongodb smallfiles true

  if [[ "$datastore_replicants" =~ , ]]
  then
    # This mongod will be part of a replicated setup.

    # Enable the REST API.
    set_mongodb rest true

    # Enable journaling for writes.
    set_mongodb journal true

    # Enable replication.
    set_mongodb replSet "$mongodb_replset"

    # Configure a key for the replica set.
    set_mongodb keyFile '/etc/mongodb.keyfile'

    rm -f '/etc/mongodb.keyfile'
    echo "$mongodb_key" > '/etc/mongodb.keyfile'
    chown -v 'mongodb.mongodb' '/etc/mongodb.keyfile'
    chmod -v 400 '/etc/mongodb.keyfile'
  fi

  # If mongod is running on a separate host from the broker OR
  # we are configuring a replica set, open up the firewall to allow
  # other broker or datastore hosts to connect.
  if broker && ! [[ "$datastore_replicants" =~ , ]]
  then
    echo 'The broker and data store are on the same host.'
    echo 'Skipping firewall and mongod configuration;'
    echo 'mongod will only be accessible over localhost.'
  else
    echo 'The data store needs to be accessible externally.'

    echo 'Configuring the firewall to allow connections to mongod...'
    firewall_allow[mongodb]='tcp:27017'

    echo 'Configuring mongod to listen on all interfaces...'
    set_mongodb bind_ip '0.0.0.0'
  fi

  # Configure mongod to start on boot.
  chkconfig mongod on

  # Start mongod so we can perform some administration now.
  service mongod start

  if ! [[ "$datastore_replicants" =~ , ]]
  then
    # This mongod will _not_ be part of a replicated setup.
    configure_datastore_add_users
  fi

  RESTART_NEEDED=true
}


# Open up services required on the node for apps and developers.
#
# Note: This function must only be run after configure_firewall.
configure_port_proxy()
{
  chkconfig openshift-iptables-port-proxy on
  sed -i '/:OUTPUT ACCEPT \[.*\]/a \
:rhc-app-comm - [0:0]' '/etc/sysconfig/iptables'
  sed -i '/-A INPUT -i lo -j ACCEPT/a \
-A INPUT -j rhc-app-comm' '/etc/sysconfig/iptables'
}

configure_gears()
{
  # Make sure that gears are restarted on reboot.
  chkconfig openshift-gears on

  # configure gear logging
  if [[ "$log_to_syslog" = *gears* ]]
  then
    # make the gear app servers log to syslog by default (overrideable)
    sed -i -e '
      /outputtype\b/I coutputType = syslog
      /outputtypefromenviron/I coutputTypeFromEnviron = true
    ' '/etc/openshift/logshifter.conf'
    # use rsyslog7 so we can annotate
    # disable some of the stock options shipped
    sed -i -e '
      /ModLoad imuxsock/ s/^/#/     # will load separately with custom options
      /var\/log\/messages/ s/^/#/   # disable original messages log
      /ModLoad imjournal/ s/^/#/    # imjournal module is not even available...
      /IMJournalStateFile/ s/^/#/
      /OmitLocalLogging/ s/^/#/
    ' '/etc/rsyslog.conf'
    # enable custom log format via imuxsock
    cat <<'LOGCONF' >> '/etc/rsyslog.d/imuxsock-and-openshift-gears.conf'
# load the modules as necessary for gear logs to be annotated
module(load="imuxsock" SysSock.Annotate="on" SysSock.ParseTrusted="on" SysSock.UsePIDFromSystem="on")
module(load="mmopenshift")

# template for gear logs that adds annotations
template(name="OpenShift" type="list") {
        property(name="timestamp")
        constant(value=" ")
        property(name="hostname")
        constant(value=" ")
        property(name="syslogtag")
        constant(value=" app=")
        property(name="$!OpenShift!OPENSHIFT_APP_NAME")
        constant(value=" ns=")
        property(name="$!OpenShift!OPENSHIFT_NAMESPACE")
        constant(value=" appUuid=")
        property(name="$!OpenShift!OPENSHIFT_APP_UUID")
        constant(value=" gearUuid=")
        property(name="$!OpenShift!OPENSHIFT_GEAR_UUID")
        property(name="msg" spifno1stsp="on")
        property(name="msg" droplastlf="on")
        constant(value="\n")
}

# direct syslog entries appropriately
action(type="mmopenshift")
if $!OpenShift!OPENSHIFT_APP_UUID != '' then
  # annotate and log syslog output from gears specially
  *.* action(type="omfile" file="/var/log/openshift_gears" template="OpenShift")
else
  # otherwise send syslog where it usually goes
  *.info;mail.none;authpriv.none;cron.none      action(type="omfile" file="/var/log/messages")

LOGCONF
    chkconfig rsyslog on
    service rsyslog restart
  fi
}

# Enable services to start on boot for the node.
enable_services_on_node()
{
  firewall_allow[https]='tcp:443'
  firewall_allow[http]='tcp:80'

  # Allow connections to openshift-node-web-proxy
  firewall_allow[ws]='tcp:8000'
  firewall_allow[wss]='tcp:8443'

  # Allow connections to openshift-sni-proxy
  if is_true "$enable_sni_proxy"
  then
    firewall_allow[sni]="tcp:${sni_first_port}:${sni_last_port}"
    chkconfig openshift-sni-proxy on
  else
    chkconfig openshift-sni-proxy off
  fi

  chkconfig httpd on
  chkconfig network on
  is_true "$enable_ntp" && chkconfig ntpd on
  chkconfig sshd on
  chkconfig oddjobd on
  chkconfig openshift-node-web-proxy on
  chkconfig openshift-watchman on
}


# Enable services to start on boot for the broker and fix up some issues.
enable_services_on_broker()
{
  firewall_allow[https]='tcp:443'
  firewall_allow[http]='tcp:80'

  chkconfig httpd on
  chkconfig network on
  is_true "$enable_ntp" && chkconfig ntpd on
  chkconfig sshd on
}


generate_mcollective_pools_configuration()
{
  local num_replicants=0
  local members=
  local new_member
  local replicant
  for replicant in ${activemq_replicants//,/ }
  do
    let num_replicants=num_replicants+1
    new_member="plugin.activemq.pool.${num_replicants}.host = $replicant
plugin.activemq.pool.${num_replicants}.port = 61613
plugin.activemq.pool.${num_replicants}.user = $mcollective_user
plugin.activemq.pool.${num_replicants}.password = $mcollective_password
"
    members="${members}${new_member}"
  done

  printf 'plugin.activemq.pool.size = %d\n%s' "$num_replicants" "$members"
}

# Configure mcollective on the broker to use ActiveMQ.
#
# logger_type = file cannot be set for OpenShift Enterprise
#  * log to console instead
# https://bugzilla.redhat.com/show_bug.cgi?id=963332
configure_mcollective_for_activemq_on_broker()
{
  local mcollective_cfg='/opt/rh/ruby193/root/etc/mcollective/client.cfg'
  cat <<EOF > "$mcollective_cfg"
main_collective = mcollective
collectives = mcollective
libdir = /opt/rh/ruby193/root/usr/libexec/mcollective
logger_type = console
loglevel = warn
direct_addressing = 0

# Plugins
securityprovider=psk
plugin.psk = asimplething

connector = activemq
$(generate_mcollective_pools_configuration)
# For further options on heartbeats and timeouts, refer to
# https://docs.puppetlabs.com/mcollective/reference/plugins/connector_activemq.html
plugin.activemq.heartbeat_interval = 30
plugin.activemq.max_hbread_fails = 2
plugin.activemq.max_hbrlck_fails = 2
# Broker will retry ActiveMQ connection, then report error
plugin.activemq.initial_reconnect_delay = 0.1
plugin.activemq.max_reconnect_attempts = 6

# Facts
factsource = yaml
plugin.yaml = /opt/rh/ruby193/root/etc/mcollective/facts.yaml

EOF

  chown 'apache:apache' "$mcollective_cfg"
  chmod 640 "$mcollective_cfg"

  RESTART_NEEDED=true
}


# Configure mcollective on the node to use ActiveMQ.
configure_mcollective_for_activemq_on_node()
{
  cat <<EOF > '/opt/rh/ruby193/root/etc/mcollective/server.cfg'
main_collective = mcollective
collectives = mcollective
libdir = /opt/rh/ruby193/root/usr/libexec/mcollective
logfile = /var/log/openshift/node/ruby193-mcollective.log
loglevel = debug

daemonize = 1
direct_addressing = 0

# Plugins
securityprovider = psk
plugin.psk = asimplething

connector = activemq
$(generate_mcollective_pools_configuration)
# For further options on heartbeats and timeouts, refer to
# https://docs.puppetlabs.com/mcollective/reference/plugins/connector_activemq.html
plugin.activemq.heartbeat_interval = 30
plugin.activemq.max_hbread_fails = 2
plugin.activemq.max_hbrlck_fails = 2
# Node should retry connecting to ActiveMQ forever
plugin.activemq.max_reconnect_attempts = 0
plugin.activemq.initial_reconnect_delay = 0.1
plugin.activemq.max_reconnect_delay = 4.0

# Facts
factsource = yaml
plugin.yaml = /opt/rh/ruby193/root/etc/mcollective/facts.yaml
EOF

  chkconfig ruby193-mcollective on

  RESTART_NEEDED=true
}


install_activemq_pkgs()
{
  yum_install_or_exit activemq
}

configure_activemq()
{
  local networkConnectors=
  local authenticationUser_amq=
  function allow_openwire() { false; }
  local replicant
  for replicant in ${activemq_replicants//,/ }
  do
    if [[ "$replicant" != "$activemq_hostname" ]]
    then
      : ${networkConnectors:='        <networkConnectors>'$'\n'}
      : ${authenticationUser_amq:="<authenticationUser username=\"amq\" password=\"${activemq_amq_user_password}\" groups=\"admins,everyone\" />"}
      function allow_openwire() { true; }
      networkConnectors="$networkConnectors            <!--"$'\n'
      networkConnectors="$networkConnectors                 Create a pair of network connectors to each other"$'\n'
      networkConnectors="$networkConnectors                 ActiveMQ broker.  It is necessary to have separate"$'\n'
      networkConnectors="$networkConnectors                 connectors for topics and queues because we need to"$'\n'
      networkConnectors="$networkConnectors                 leave conduitSubscriptions enabled for topics in order"$'\n'
      networkConnectors="$networkConnectors                 to avoid duplicate messages and disable it for queues"$'\n'
      networkConnectors="$networkConnectors                 in order to ensure that JMS selectors are propagated."$'\n'
      networkConnectors="$networkConnectors                 In particular, the OpenShift broker uses the"$'\n'
      networkConnectors="$networkConnectors                 mcollective.node queue to directly address nodes,"$'\n'
      networkConnectors="$networkConnectors                 which subscribe to the queue using JMS selectors."$'\n'
      networkConnectors="$networkConnectors            -->"$'\n'
      networkConnectors="$networkConnectors            <networkConnector name=\"${activemq_hostname}-${replicant}-topics\" uri=\"static:(tcp://${replicant}:61616)\" userName=\"amq\" password=\"${activemq_amq_user_password}\">"$'\n'
      networkConnectors="$networkConnectors                <excludedDestinations>"$'\n'
      networkConnectors="$networkConnectors                    <queue physicalName=\">\" />"$'\n'
      networkConnectors="$networkConnectors                </excludedDestinations>"$'\n'
      networkConnectors="$networkConnectors            </networkConnector>"$'\n'
      networkConnectors="$networkConnectors            <networkConnector name=\"${activemq_hostname}-${replicant}-queues\" uri=\"static:(tcp://${replicant}:61616)\" userName=\"amq\" password=\"${activemq_amq_user_password}\" conduitSubscriptions=\"false\">"$'\n'
      networkConnectors="$networkConnectors                <excludedDestinations>"$'\n'
      networkConnectors="$networkConnectors                    <topic physicalName=\">\" />"$'\n'
      networkConnectors="$networkConnectors                </excludedDestinations>"$'\n'
      networkConnectors="$networkConnectors            </networkConnector>"$'\n'
    fi
  done
  networkConnectors="${networkConnectors:+$networkConnectors    </networkConnectors>$'\n'}"

  local schedulerSupport= routingPolicy=
  if is_true "$enable_routing_plugin"
  then
    schedulerSupport='schedulerSupport="true"'
    IFS= read -r -d '' routingPolicy <<'EOF' || :
          <redeliveryPlugin fallbackToDeadLetter="true"
                            sendToDlqIfMaxRetriesExceeded="true">
            <redeliveryPolicyMap>
              <redeliveryPolicyMap>
                <redeliveryPolicyEntries>
                  <redeliveryPolicy queue="routinginfo"
                                    maximumRedeliveries="4"
                                    useExponentialBackOff="true"
                                    backOffMultiplier="4"
                                    initialRedeliveryDelay="2000" />
                </redeliveryPolicyEntries>
              </redeliveryPolicyMap>
            </redeliveryPolicyMap>
          </redeliveryPlugin>
EOF
  fi

  cat <<EOF > '/etc/activemq/activemq.xml'
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
    <broker xmlns="http://activemq.apache.org/schema/core"
            brokerName="${activemq_hostname}"
            dataDirectory="\${activemq.data}"
            schedulePeriodForDestinationPurge="60000"
            ${schedulerSupport}>

        <destinationPolicy>
            <policyMap>
                <policyEntries>
                    <!--
                      The Puppet Labs documentation for MCollective
                      advises disabling producerFlowControl for all
                      topics in order to avoid MCollective servers
                      appearing blocked during heavy traffic.

                      For more information, see:
                      http://docs.puppetlabs.com/mcollective/deploy/middleware/activemq.html
                    -->
                    <policyEntry topic=">" producerFlowControl="false" />
                    <!--
                      The Puppet Labs documentation advises enabling
                      garbage-collection of queues because MCollective
                      creates a uniquely named, single-use queue for
                      each reply.

                      For more information, see:
                      http://docs.puppetlabs.com/mcollective/deploy/middleware/activemq.html
                    -->
                    <policyEntry queue="*.reply.>" gcInactiveDestinations="true" inactiveTimoutBeforeGC="300000" />
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

$networkConnectors

        <!-- add users for mcollective -->

        <plugins>
          <statisticsBrokerPlugin/>
          <simpleAuthenticationPlugin>
             <users>
               <authenticationUser username="${mcollective_user}" password="${mcollective_password}" groups="mcollective,everyone"/>
               $authenticationUser_amq
               <authenticationUser username="admin" password="${activemq_admin_password}" groups="mcollective,admin,everyone"/>
               $( if is_true "$enable_routing_plugin"
                  then echo "<authenticationUser username=\"${routing_plugin_user}\" password=\"${routing_plugin_pass}\" groups=\"routinginfo,everyone\"/>"
                  fi
               )
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
                  $( if is_true "$enable_routing_plugin"
                     then
                       echo '<authorizationEntry topic="routinginfo.>" write="routinginfo" read="routinginfo" admin="routinginfo" />'
                       echo '<authorizationEntry queue="routinginfo.>" write="routinginfo" read="routinginfo" admin="routinginfo" />'
                     fi
                  )
                </authorizationEntries>
              </authorizationMap>
            </map>
          </authorizationPlugin>
$routingPolicy
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
	Enable web consoles, REST and Ajax APIs and demos. Unneeded for
        OpenShift Enterprise and therefore disabled by default.

        Take a look at \${ACTIVEMQ_HOME}/conf/jetty.xml for more details

        If enabling the web console, you should make sure to require
        authentication in jetty.xml and configure the admin/user
        passwords in jetty-realm.properties.

        <import resource="jetty.xml"/>
    -->

</beans>
<!-- END SNIPPET: example -->
EOF

  # Allow connections to ActiveMQ.
  firewall_allow[stomp]='tcp:61613'
  allow_openwire && firewall_allow[openwire]='tcp:61616'

  # Configure ActiveMQ to start on boot.
  chkconfig activemq on

  RESTART_NEEDED=true
}

install_named_pkgs()
{
  yum_install_or_exit bind bind-utils
}

configure_named()
{
  # Ensure we have a key for service named status to communicate with BIND.
  rndc-confgen -a -r '/dev/urandom'
  restorecon /etc/rndc.* /etc/named.*
  chown 'root:named' '/etc/rndc.key'
  chmod 640 '/etc/rndc.key'

  # Set up DNS forwarding if so directed.
  local forwarders='recursion no;'
  if is_true "$enable_dns_forwarding"
  then
    echo "forwarders { ${nameservers} } ;" > '/var/named/forwarders.conf'
    restorecon '/var/named/forwarders.conf'
    chmod 644 '/var/named/forwarders.conf'
    forwarders='// set forwarding to the next nearest server (from DHCP response)
	forward only;
        include "forwarders.conf";
	recursion yes;
'
  fi

  # Install the configuration file for the OpenShift Enterprise domain
  # name.
  rm -rf '/var/named/dynamic'
  mkdir -p '/var/named/dynamic'

  chgrp named -R '/var/named'
  chown named -R '/var/named/dynamic'
  restorecon -rv '/var/named'

  # Replace named.conf.
  cat <<EOF > '/etc/named.conf'
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
        allow-transfer  { "none"; }; # default to no zone transfers

	/* Path to ISC DLV key */
	bindkeys-file "/etc/named.iscdlv.key";

	$forwarders
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
EOF
  chown 'root:named' '/etc/named.conf'
  chcon 'system_u:object_r:named_conf_t:s0' -v '/etc/named.conf'

  # actually set up the domain zone(s)
  # bind_key is used if set, created if not. both domains use same key.
  configure_named_zone "$hosts_domain"
  [[ "$domain" != "$hosts_domain" ]] && configure_named_zone "$domain"

  # configure in any hosts as needed
  configure_hosts_dns

  # Configure named to start on boot.
  firewall_allow[dns]='tcp:53,udp:53'
  chkconfig named on

  # Start named so we can perform some updates immediately.
  service named start
}

configure_named_zone()
{
  local zone="$1"

  if [[ -z "$bind_key" ]]
  then
    # Generate a new secret key
    local zone_tolower="${zone,,}"
    rm -f "/var/named/K${zone_tolower}"*
    dnssec-keygen -a "$bind_keyalgorithm" -b "$bind_keysize" -n USER -r '/dev/urandom' -K '/var/named' "$zone"
    # $zone may have uppercase letters in it.  However the file that
    # dnssec-keygen creates will have the zone in lowercase.
    bind_key="$(grep 'Key:' "/var/named/K${zone_tolower}"*.private | cut -d ' ' -f 2)"
    rm -f "/var/named/K${zone_tolower}"*
  fi

  # Install the key where BIND and oo-register-dns expect it.
  cat <<EOF > "/var/named/${zone}.key"
key $zone {
  algorithm "${bind_keyalgorithm}";
  secret "${bind_key}";
};
EOF

  # Create the initial BIND database.
  cat <<EOF > "/var/named/dynamic/${zone}.db"
\$ORIGIN .
\$TTL 1	; 1 seconds (for testing only)
${zone}		IN SOA	${named_hostname}. hostmaster.${zone}. (
				2011112904 ; serial
				60         ; refresh (1 minute)
				15         ; retry (15 seconds)
				1800       ; expire (30 minutes)
				10         ; minimum (10 seconds)
				)
				IN NS	${named_hostname}.
				IN MX	10 mail.${zone}.
\$ORIGIN ${zone}.
EOF

  # Add a record for the zone to named conf
  cat <<EOF >> '/etc/named.conf'
include "${zone}.key";

zone "${zone}" IN {
	type master;
	file "dynamic/${zone}.db";
	allow-update { key $zone ; } ;
};
EOF
}

# Add a domain to the given hostname if it does not have one.
# $1 = host
# $2 = domain
ensure_domain()
{
  if [[ "$1" = *.* ]]
  then # $1 is already a FQDN or IP address.
    echo "$1"
  else # $1 needs a domain appended.
    echo "$1.$2"
  fi
}

# $1 = host
# $2 = ip
# $3 = zone (optional)
add_host_to_zone()
{
  local zone="${3:-$hosts_domain}"
  local nsdb="/var/named/dynamic/${zone}.db"
  # Check that $1 isn't an IP address and that $2 is.
  # All numbers and dots = IP address (not rigorous).
  local ip_regex='^[.0-9]+$'
  if [[ "$1" =~ $ip_regex || ! "$2" =~ $ip_regex ]]
  then echo "Not adding DNS record to host zone: '$1' should be a hostname and '$2' should be an IP address"
  else echo "${1%.${zone}}			IN A	$2" >> "$nsdb"
  fi
}

configure_hosts_dns()
{
  # Always define self.
  add_host_to_zone "$named_hostname" "$named_ip_addr"

  # Add the glue record for the NS host in the subdomain.
  [[ "$hosts_domain" = *?"$domain" ]] && add_host_to_zone "$named_hostname" "$named_ip_addr" "$domain"

  if [[ -z "$named_entries" ]]
  then
    # Add A records for any other components that are being installed locally.
    broker && add_host_to_zone "$broker_hostname" "$broker_ip_addr"
    node && add_host_to_zone "$node_hostname" "$node_ip_addr"
    activemq && add_host_to_zone "$activemq_hostname" "$cur_ip_addr"
    datastore && add_host_to_zone "$datastore_hostname" "$cur_ip_addr"
    router && add_host_to_zone "$router_hostname" "$cur_ip_addr" "$domain"
  elif [[ "$named_entries" =~ : ]]
  then
    # Add any A records for host:ip pairs passed in via CONF_NAMED_ENTRIES
    local host_ip
    # We want word-splitting on $named_entries and $host_ip.
    for host_ip in ${named_entries//,/ }
    do add_host_to_zone ${host_ip//:/ }
    done
  else # If "none" is specified, then just don't add anything.
    echo "Not adding named entries; named_entries = $named_entries"
  fi

  return 0
}

# An alternate method for registering against a running named
# using oo-register-dns. Not used by default.
register_named_entries()
{
  # All numbers and dots = IP address (not rigorous).
  local ip_regex='^[.0-9]+$'
  local failed=false
  local host_ip
  local host
  local ip
  for host_ip in ${named_entries//,/ }
  do
    read host ip <<< "${host_ip//:/ }"
    if [[ "$host" =~ $ip_regex || ! "$ip" =~ $ip_regex ]]
    then
      echo "Not adding DNS record to host zone: '$host' should be a hostname and '$ip' should be an IP address"
    elif ! oo-register-dns -d "$hosts_domain" -h "${host%.$hosts_domain}" -k "$hosts_domain_keyfile" -n "$ip"
    then
      echo "WARNING: Failed to register host $host with IP $ip"
      failed=true
    fi
  done
  "$failed" && echo 'OpenShift: Completed updating host DNS entries.'
  return 0
}

configure_network()
{
  # Ensure interface is configured to come up on boot
  set_conf "/etc/sysconfig/network-scripts/ifcfg-$interface" ONBOOT yes

  # Check if static IP configured
  if grep -q IPADDR "/etc/sysconfig/network-scripts/ifcfg-$interface"
  then
    set_conf "/etc/sysconfig/network-scripts/ifcfg-$interface" BOOTPROTO none
    set_conf "/etc/sysconfig/network-scripts/ifcfg-$interface" IPV6INIT no
  fi
}

# Make resolv.conf point to our named service, which will resolve the
# host names used in this installation of OpenShift.  Our named service
# will forward other requests to some other DNS servers.
configure_dns_resolution()
{
  # Update resolv.conf to use our named.
  #
  # We will keep any existing entries so that we have fallbacks that
  # will resolve public addresses even when our private named is
  # nonfunctional.  However, our private named must appear first in
  # order for hostnames private to our OpenShift PaaS to resolve.
  sed -i -e "/search/ d; 1i# The named we install for our OpenShift PaaS must appear first.\\nsearch ${hosts_domain}.\\nnameserver ${named_ip_addr}\\n" '/etc/resolv.conf'

  # Append resolution conf to the DHCP configuration.
  sed -i -e "/prepend domain-name-servers ${named_ip_addr};/d" "/etc/dhcp/dhclient-${interface}.conf"
  sed -i -e "/prepend domain-search ${hosts_domain};/d" "/etc/dhcp/dhclient-${interface}.conf"
  cat <<EOF >> "/etc/dhcp/dhclient-${interface}.conf"

prepend domain-name-servers ${named_ip_addr};
prepend domain-search "${hosts_domain}";
EOF
}

update_controller_gear_size_configs()
{
  # Configure the valid gear sizes, default gear capabilities and default gear
  # size for the broker
  set_broker VALID_GEAR_SIZES "$valid_gear_sizes"
  set_broker DEFAULT_GEAR_CAPABILITIES "$default_gear_capabilities"
  set_broker DEFAULT_GEAR_SIZE "$default_gear_size"

  RESTART_NEEDED=true
}

# Update the controller configuration.
configure_controller()
{
  if [[ -z "$broker_auth_salt" ]]
  then
    echo 'Warning: broker authentication salt is empty!'
  fi

  # Configure the broker with the correct domain name, and use random salt
  # to the data store (the host running MongoDB).
  set_broker CLOUD_DOMAIN "$domain"
  set_broker AUTH_SALT "$broker_auth_salt"

  update_controller_gear_size_configs

  # Configure the session secret for the broker
  set_broker SESSION_SECRET "$broker_session_secret"

  # Configure the session secret for the console
  set_console SESSION_SECRET "$console_session_secret"

  if is_true "$enable_ha"
  then
    # Enable highly available applications, manage DNS CNAME records for highly
    # available access to applications where those records will point to the
    # external router, and grant permission to create HA applications to new
    # accounts by default.
    set_broker ALLOW_HA_APPLICATIONS true
    set_broker MANAGE_HA_DNS true
    set_broker DEFAULT_ALLOW_HA true
    set_broker ROUTER_HOSTNAME "$router_hostname"
  fi

  if [[ "$datastore_replicants" =~ , ]] || ! datastore
  then
    # MongoDB may be installed remotely or replicated, so configure it
    # with the given hostname(s).
    set_broker MONGO_HOST_PORT "$datastore_replicants"
  fi

  # configure MongoDB access
  set_broker MONGO_PASSWORD "$mongodb_broker_password"
  set_broker MONGO_USER "$mongodb_broker_user"
  set_broker MONGO_DB "$mongodb_name"

  # configure broker logs for syslog
  [[ "$log_to_syslog" = *broker* ]] &&
    set_broker SYSLOG_ENABLED true
  [[ "$log_to_syslog" = *console* ]] &&
    set_console SYSLOG_ENABLED true

  # Set the ServerName for httpd
  sed -i -e "s/ServerName .*\$/ServerName ${hostname}/" \
      '/etc/httpd/conf.d/000002_openshift_origin_broker_servername.conf'

  # Configure the broker service to start on boot.
  chkconfig openshift-broker on
  chkconfig openshift-console on

  RESTART_NEEDED=true
}

# $1 = ports per gear (optional)
configure_messaging_plugin()
{
  local ports="${1:-$ports_per_gear}"
  local pool_size=6000
  let "pool_size=30000/$ports"

  local file='/etc/openshift/plugins.d/openshift-origin-msg-broker-mcollective.conf'
  cp "$file"{.example,}
  set_conf "$file" DISTRICTS_FIRST_UID "$district_first_uid"
  set_conf "$file" DISTRICTS_MAX_CAPACITY "$pool_size"
  RESTART_NEEDED=true
}

# Configure the broker to use the BIND DNS plug-in.
configure_dns_plugin()
{
  if [[ -z "$bind_key" && -z "$bind_krb_keytab" ]]
  then
    echo 'WARNING: Neither key nor keytab has been set for communication'
    echo 'with BIND. You will need to modify the value of BIND_KEYVALUE'
    echo 'and BIND_KEYALGORITHM in /etc/openshift/plugins.d/openshift-origin-dns-nsupdate.conf'
    echo 'after installation.'
  fi

  mkdir -p '/etc/openshift/plugins.d'
  cat <<EOF > '/etc/openshift/plugins.d/openshift-origin-dns-nsupdate.conf'
BIND_SERVER="${named_ip_addr}"
BIND_PORT=53
BIND_ZONE="${domain}"
EOF
  if [[ -z "$bind_krb_keytab" ]]
  then
    cat <<EOF >> '/etc/openshift/plugins.d/openshift-origin-dns-nsupdate.conf'
BIND_KEYNAME="${domain}"
BIND_KEYVALUE="${bind_key}"
BIND_KEYALGORITHM="${bind_keyalgorithm}"
EOF
  else
    cat <<EOF >> '/etc/openshift/plugins.d/openshift-origin-dns-nsupdate.conf'
BIND_KRB_PRINCIPAL="${bind_krb_principal}"
BIND_KRB_KEYTAB="${bind_krb_keytab}"
EOF
  fi

  RESTART_NEEDED=true
}

# Configure httpd for authentication.
configure_httpd_auth()
{
  # Configure the broker to use the remote-user authentication plugin.
  cp -p '/etc/openshift/plugins.d/openshift-origin-auth-remote-user.conf'{.example,}

  # Configure mod_auth_kerb if both CONF_BROKER_KRB_SERVICE_NAME
  # and CONF_BROKER_KRB_AUTH_REALMS are specified
  if [[ -n "$broker_krb_service_name" && -n "$broker_krb_auth_realms" ]]
  then
    yum_install_or_exit mod_auth_kerb
    local d
    for d in '/var/www/openshift/broker/httpd/conf.d' '/var/www/openshift/console/httpd/conf.d'
    do
      sed -e "s#KrbServiceName.*#KrbServiceName ${broker_krb_service_name}#" \
          -e "s#KrbAuthRealms.*#KrbAuthRealms ${broker_krb_auth_realms}#" \
          "$d/openshift-origin-auth-remote-user-kerberos.conf.sample" \
          > "$d/openshift-origin-auth-remote-user-kerberos.conf"
    done
    return
  fi

  # Install the Apache Basic Authentication configuration file.
  cp -p '/var/www/openshift/broker/httpd/conf.d/openshift-origin-auth-remote-user-basic.conf.sample' \
     '/var/www/openshift/broker/httpd/conf.d/openshift-origin-auth-remote-user.conf'

  cp -p '/var/www/openshift/console/httpd/conf.d/openshift-origin-auth-remote-user-basic.conf.sample' \
     '/var/www/openshift/console/httpd/conf.d/openshift-origin-auth-remote-user.conf'

  # The above configuration file configures Apache to use
  # /etc/openshift/htpasswd for its password file.
  #
  # Here we create a test user:
  htpasswd -bc '/etc/openshift/htpasswd' "$openshift_user1" "$openshift_password1"
  #
  # Use the following command to add more users:
  #
  #  htpasswd /etc/openshift/htpasswd username

  # TODO: In the future, we will want to edit
  # /etc/openshift/plugins.d/openshift-origin-auth-remote-user.conf to
  # put in a random salt.

  RESTART_NEEDED=true
}

configure_routing_daemon()
{
  # The routing daemon runs on the broker in the case that $router = f5
  # or on the router in the case that $router = nginx.
  [[ -z "$router" ]] && return 0
  [[ "$router" = f5 ]] && ! broker && return 0
  [[ "$router" = nginx ]] && ! router && return 0

  set_routing_daemon LOAD_BALANCER "$router"
  set_routing_daemon ACTIVEMQ_HOST "$activemq_replicants"
  set_routing_daemon ACTIVEMQ_USER "$routing_plugin_user"
  set_routing_daemon ACTIVEMQ_PASSWORD "$routing_plugin_pass"
  set_routing_daemon CLOUD_DOMAIN "$domain"

  # Comment out any settings that are not related to the configured
  # load-balancer.
  [[ "$router" != f5 ]] && sed -i -e 's/^\(UPDATE_INTERVAL\|MONITOR_\|VIRTUAL_\|BIGIP_\|LBAAS_\)/#&/' '/etc/openshift/routing-daemon.conf'
  [[ "$router" != nginx ]] && sed -i -e 's/^NGINX_/#&/' '/etc/openshift/routing-daemon.conf'

  chkconfig openshift-routing-daemon on
  RESTART_NEEDED=true
}

configure_routing_plugin()
{
  if is_true "$enable_routing_plugin"
  then
    local conffile='/etc/openshift/plugins.d/openshift-origin-routing-activemq.conf'
    sed -e '/^ACTIVEMQ_\(USERNAME\|PASSWORD\|HOST\)/ d' "${conffile}.example" > "$conffile"
    cat <<EOF >> "$conffile"
ACTIVEMQ_HOST='${activemq_replicants}'
ACTIVEMQ_USERNAME='${routing_plugin_user}'
ACTIVEMQ_PASSWORD='${routing_plugin_pass}'
EOF
    RESTART_NEEDED=true
  fi
}

# if the broker and node are on the same machine we need to manually update the
# config so that node doesn't intercept broker requests
fix_broker_routing()
{
  case "$node_apache_frontend" in
    vhost)
      # node vhost obscures the broker vhost unless we bring the broker conf forward
      if [[ ! -e '/etc/httpd/conf.d/000000_openshift_origin_broker_proxy.conf' ]]
      then ln -s /etc/httpd/conf.d/00000{2,0}_openshift_origin_broker_proxy.conf
      fi
      ;;
    mod_rewrite)
      # node vhost obscures the broker vhost still, but can let specific requests past
      cat <<EOF >> '/var/lib/openshift/.httpd.d/nodes.txt'
__default__ REDIRECT:/console
__default__/rsync_id_rsa.pub NOPROXY
__default__/console TOHTTPS:127.0.0.1:8118/console
__default__/broker TOHTTPS:127.0.0.1:8080/broker
__default__/admin-console TOHTTPS:127.0.0.1:8080/admin-console
__default__/assets TOHTTPS:127.0.0.1:8080/assets
EOF

      httxt2dbm -f DB -i '/etc/httpd/conf.d/openshift/nodes.txt' -o '/etc/httpd/conf.d/openshift/nodes.db'
      chown 'root:apache' '/etc/httpd/conf.d/openshift/nodes.txt' '/etc/httpd/conf.d/openshift/nodes.db'
      chmod 750 '/etc/httpd/conf.d/openshift/nodes.txt' '/etc/httpd/conf.d/openshift/nodes.db'
      ;;
    *)
      echo "Invalid value: CONF_NODE_APACHE_FRONTEND=$node_apache_frontend"
      abort_install
      ;;
  esac
}

configure_router()
{
  case "$router" in
    (f5)
      # Nothing to do; configuration of F5 is outside the scope of this script.
      ;;
    (nginx)
      firewall_allow[https]='tcp:443'
      firewall_allow[http]='tcp:80'
      setsebool -P httpd_can_network_connect=true
      chkconfig nginx16-nginx on
      RESTART_NEEDED=true
      ;;
  esac
}

configure_access_keys_on_broker()
{
  # Generate a broker access key for remote apps (Jenkins) to access
  # the broker.
  echo "$broker_auth_priv_key" > '/etc/openshift/server_priv.pem'
  openssl rsa -in '/etc/openshift/server_priv.pem' -pubout > '/etc/openshift/server_pub.pem'
  chown 'apache:apache' '/etc/openshift/server_pub.pem'
  chmod 640 '/etc/openshift/server_pub.pem'

  # If a key pair already exists, delete it so that the ssh-keygen
  # command will not have to ask the user what to do.
  rm -f '/root/.ssh/rsync_id_rsa' '/root/.ssh/rsync_id_rsa.pub'

  # Generate a key pair for moving gears between nodes from the broker.
  ssh-keygen -t rsa -b 2048 -P '' -f '/root/.ssh/rsync_id_rsa'
  cp /root/.ssh/rsync_id_rsa* '/etc/openshift/'
  # the .pub key needs to go on nodes. So, we provide it via a standard
  # location on httpd:
  cp '/root/.ssh/rsync_id_rsa.pub' '/var/www/html/'
  # The node install script can retrieve this or it can be performed manually:
  #   # wget -q -O- --no-check-certificate https://${broker_hostname}/rsync_id_rsa.pub?host=${node_hostname} >> /root/.ssh/authorized_keys
  # In order to enable this during the install, we turn on httpd.
  service httpd start
}

configure_wildcard_ssl_cert_on_node()
{
  # Generate a 2048 bit key and self-signed cert.
  cat << EOF | openssl req -new -rand /dev/urandom \
	-newkey 'rsa:2048' -nodes -keyout '/etc/pki/tls/private/localhost.key' \
	-x509 -days 3650 \
	-out '/etc/pki/tls/certs/localhost.crt' 2> /dev/null
XX
SomeState
SomeCity
OpenShift Enterprise default
Temporary certificate
*.$domain
root@$domain
EOF

}

configure_broker_ssl_cert()
{
  # Generate a 2048 bit key and self-signed cert
  cat << EOF | openssl req -new -rand '/dev/urandom' \
	-newkey 'rsa:2048' -nodes -keyout '/etc/pki/tls/private/localhost.key' \
	-x509 -days 3650 \
	-out '/etc/pki/tls/certs/localhost.crt' 2> /dev/null
XX
SomeState
SomeCity
OpenShift Enterprise default
Temporary certificate
$broker_hostname
root@$domain
EOF
}

# Set the hostname
configure_hostname()
{
  if [[ ! "$hostname" =~ ^[0-9.]*$ ]]  # hostname is not just an IP
  then
    set_conf '/etc/sysconfig/network' HOSTNAME "$hostname"
    hostname "$hostname"
  fi
}

# Set some parameters in the OpenShift node configuration files.
configure_node()
{
  local resrc='/etc/openshift/resource_limits.conf'
  if [[ -f "${resrc}.${node_profile}.${node_host_type}" ]]
  then cp "${resrc}.${node_profile}.${node_host_type}" "$resrc"
  elif [[ -f "${resrc}.${node_profile}" ]]
  then cp "${resrc}.${node_profile}" "$resrc"
  fi
  set_conf "$resrc" node_profile "$node_profile_name"

  set_node PUBLIC_IP "$node_ip_addr"
  set_node CLOUD_DOMAIN "$domain"
  set_node PUBLIC_HOSTNAME "$hostname"
  set_node BROKER_HOST "$broker_hostname"
  set_node EXTERNAL_ETH_DEV "$interface"

  if [[ "$ports_per_gear" != 5 ]]
  then
    set_node PORTS_PER_USER "$ports_per_gear" '' \
     'Number of proxy ports available per gear. Increasing the ports per gear'\
     'requires reducing the number of UIDs the district has so that the ports'\
     'allocated to all UIDs fit in the proxy port range.'
  fi

  local conf='/etc/openshift/node.conf'
  case "$node_apache_frontend" in
    mod_rewrite)
      sed -i -e "/OPENSHIFT_FRONTEND_HTTP_PLUGINS/ s/vhost/mod-rewrite/" "$conf"
      ;;
    vhost)
      sed -i -e "/OPENSHIFT_FRONTEND_HTTP_PLUGINS/ s/mod-rewrite/vhost/" "$conf"
      ;;
  esac

  if is_true "$enable_sni_proxy"
  then
    # configure in the sni proxy
    grep -q 'OPENSHIFT_FRONTEND_HTTP_PLUGINS=.*sni-proxy' "$conf" ||
      sed -i -e '/OPENSHIFT_FRONTEND_HTTP_PLUGINS/ s/=/=openshift-origin-frontend-haproxy-sni-proxy,/' "$conf"
    local port_list=$(seq -s, "$sni_first_port" "$sni_last_port")
    local sniconf='/etc/openshift/node-plugins.d/openshift-origin-frontend-haproxy-sni-proxy.conf'
    set_conf "$sniconf" PROXY_PORTS "$port_list"
  fi

  echo "$broker_hostname" > '/etc/openshift/env/OPENSHIFT_BROKER_HOST'
  echo "$domain" > '/etc/openshift/env/OPENSHIFT_CLOUD_DOMAIN'

  # Set the ServerName for httpd
  sed -i -e "s/ServerName .*$/ServerName ${hostname}/" \
      '/etc/httpd/conf.d/000001_openshift_origin_node_servername.conf'

  configure_node_logs
  RESTART_NEEDED=true
}

configure_node_logs()
{
  if [[ "$log_to_syslog" = *node* ]]
  then
    # Send the node platform logs to syslog instead.
    sed -i -e '
      # comment out existing log settings
      s/^PLATFORM_LOG_FILE/#PLATFORM_LOG_FILE/
      s/^PLATFORM_TRACE_LOG_FILE/#PLATFORM_TRACE_LOG_FILE/
      s/^PLATFORM_LOG_LEVEL/#PLATFORM_LOG_LEVEL/
      s/^PLATFORM_TRACE_LOG_LEVEL/#PLATFORM_TRACE_LOG_LEVEL/
      /PLATFORM_TRACE_LOG_LEVEL/ a\
PLATFORM_LOG_CLASS=SyslogLogger\
PLATFORM_SYSLOG_THRESHOLD=LOG_INFO\
PLATFORM_SYSLOG_TRACE_ENABLED=1
    ' '/etc/openshift/node.conf'
    echo 'local0.*  /var/log/messages' > '/etc/rsyslog.d/openshift-node-platform.conf'
  fi
  if [[ "$log_to_syslog" = *frontend* ]]
  then
    # Send the frontend logs to syslog (in addition to file).
    sed -i -e 's/^#*\s*OPTIONS="\?\([^"]*\)"\?/OPTIONS="\1 -DOpenShiftFrontendSyslogEnabled"/' '/etc/sysconfig/httpd'
  fi
  if is_true "$node_log_context"
  then
    # Annotate the frontend logs with UUIDs.
    set_node PLATFORM_LOG_CONTEXT_ENABLED 1
    set_node PLATFORM_LOG_CONTEXT_ATTRS 'request_id,app_uuid,container_uuid'
    sed -i -e 's/^#*\s*OPTIONS="\?\([^"]*\)"\?/OPTIONS="\1 -DOpenShiftAnnotateFrontendAccessLog"/' '/etc/sysconfig/httpd'
  fi
  if [[ -n "$metrics_interval" ]]
  then
    # Configure watchman with given the interval.
    set_node WATCHMAN_METRICS_ENABLED true
    set_node WATCHMAN_METRICS_INTERVAL "$metrics_interval"
  fi
}

# Run the cronjob installed by openshift-origin-msg-node-mcollective immediately
# to regenerate facts.yaml.
update_openshift_facts_on_node()
{
  /etc/cron.minutely/openshift-facts
}

# So that the broker can ssh to nodes for moving gears, get the broker's
# public key (if available) and add it to node's authorized keys.
install_rsync_pub_key()
{
  mkdir -p '/root/.ssh'
  chmod 700 '/root/.ssh'

  local wait=600
  local end=`date -d "$wait seconds" +%s`
  echo "OpenShift node: will wait for $wait seconds to fetch SSH key."

  local cert
  while [[ `date +%s` -lt "$end" ]]
  do
    # Try to get the public key from the broker.
    if ! cert="$(wget -q -O- --no-check-certificate "https://${broker_hostname}/rsync_id_rsa.pub?host=$node_hostname")"
    then
      sleep 5
    else
      if ! ssh-keygen -lf '/dev/stdin' <<< "$cert"
      then
        break
      else
        echo "$cert" >> '/root/.ssh/authorized_keys'
        echo 'OpenShift node: SSH key downloaded from broker successfully.'
        chmod 644 '/root/.ssh/authorized_keys'
        return
      fi
    fi
  done

  echo 'OpenShift node: WARNING: could not install rsync_id_rsa.pub key; please do it manually.'

}

echo_installation_intentions()
{
  echo 'The following components should be installed:'
  local components='broker node named activemq datastore'
  local component
  # We want word-splitting on $components.
  for component in $components
  do "$component" && printf '\t%s.\n' "$component"
  done

  echo "Configuring with broker with hostname ${broker_hostname}."
  node && echo "Configuring node with hostname ${node_hostname}."
  echo "Configuring with named with IP address ${named_ip_addr}."
  broker && echo "Configuring with datastore with hostname ${datastore_hostname}."
  echo "Configuring with activemq with hostname ${activemq_hostname}."
  echo "Configuring with router with hostname ${router_hostname}."
}

# Modify console message to show install info
configure_console_msg()
{
  # add the IP to /etc/issue for convenience
  echo "Install-time IP address: $cur_ip_addr" >> '/etc/issue'
  echo_installation_intentions >> '/etc/issue'
  echo 'Check /root/anaconda-post.log to see the %post output.' >> '/etc/issue'
  echo >> '/etc/issue'
}



########################################################################

# Given a list of arguments, define variables with the parameters
# specified on it so that from, e.g., "foo=bar baz" we get CONF_FOO=bar
# and CONF_BAZ=true in the environment.
parse_args()
{
  local key
  local word
  for word in "$@"
  do
    key="${word%%\=*}"
    case "$word" in
      (*=*) val="${word#*\=}" ;;
      (*) val=true ;;
    esac
    printf -v "CONF_${key^^}" '%s' "$val"
  done
}

# Parse the kernel command-line using parse_args.
parse_kernel_cmdline()
{
  # We want word-splitting on the command substitution, so don't quote it.
  parse_args $(cat /proc/cmdline)
  : "${CONF_ABORT_ON_UNRECOGNIZED_SETTINGS:=false}"
}

# Parse command-line arguments using parse_args.
parse_cmdline()
{
  parse_args "$@"
}

metapkgs_optional()
{
  [[ "${metapkgs,,}" =~ 'optional' ]]
}

metapkgs_recommended()
{
  metapkgs_optional || [[ "${metapkgs,,}" =~ 'recommended' ]]
}

is_true()
{
  for arg
  do
    [[ "$arg" =~ (1|true) ]] || return 1
  done

  return 0
}

is_false()
{
  for arg
  do
    [[ "$arg" =~ (1|true) ]] || return 0
  done

  return 1
}

# Checks $1 or $node_profile and returns true if it contains "xpaas".
is_xpaas()
{
  local profile="${1:-$node_profile}"
  [[ "$profile" = *xpaas* ]]
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
# We also set the $ose_repo_base variable with the base URL for the yum
# repositories that will be used to download OpenShift RPMs.  The value
# of this variable can be changed to use a custom repository or puddle.
#
# We also set the $cur_ip_addr variable to the IP address of the host
# running this script, based on the output of the `ip addr show` command
#
# In addition, the $nameservers variable will be set to
# a semicolon-delimited list of nameservers, suitable for use in
# named.conf, based on the existing contents of /etc/resolv.conf, and
# either $bind_krb_keytab and $bind_krb_principal will be set to the
# value of CONF_BIND_KRB_KEYTAB and CONF_BIND_KRB_PRINCIPAL, or the
# the $bind_key variable will be set to the value of CONF_BIND_KEY.
#
# This function makes use of variables that may be set by parse_kernel_cmdline
# based on the content of /proc/cmdline or may be hardcoded by modifying
# this file.  All of these variables are optional; best attempts are
# made at determining reasonable defaults.
#
set_defaults()
{
  abort_on_unrecognized_settings="${CONF_ABORT_ON_UNRECOGNIZED_SETTINGS:-true}"

  # Check for unrecognized or empty settings and warn or abort if one is found.
  #
  # The declare statement below is generated by the following command:
  #
  #   echo local -A valid_settings=\( $(grep -o 'CONF_[0-9A-Z_]\+' openshift.ks |sort -u |grep -v -F -e CONF_BAZ -e CONF_FOO |sed -e 's/.*/[&]=/') \)
local -A valid_settings=( [CONF_ABORT_ON_UNRECOGNIZED_SETTINGS]= [CONF_ACTIONS]= [CONF_ACTIVEMQ_ADMIN_PASSWORD]= [CONF_ACTIVEMQ_AMQ_USER_PASSWORD]= [CONF_ACTIVEMQ_HOSTNAME]= [CONF_ACTIVEMQ_REPLICANTS]= [CONF_AMQ_EXTRA_REPO]= [CONF_BIND_KEY]= [CONF_BIND_KEYALGORITHM]= [CONF_BIND_KEYSIZE]= [CONF_BIND_KEYVALUE]= [CONF_BIND_KRB_KEYTAB]= [CONF_BIND_KRB_PRINCIPAL]= [CONF_BROKER_AUTH_PRIV_KEY]= [CONF_BROKER_AUTH_SALT]= [CONF_BROKER_HOSTNAME]= [CONF_BROKER_IP_ADDR]= [CONF_BROKER_KRB_AUTH_REALMS]= [CONF_BROKER_KRB_SERVICE_NAME]= [CONF_BROKER_SESSION_SECRET]= [CONF_CARTRIDGES]= [CONF_CDN_LAYOUT]= [CONF_CDN_REPO_BASE]= [CONF_CONSOLE_SESSION_SECRET]= [CONF_DATASTORE_HOSTNAME]= [CONF_DATASTORE_REPLICANTS]= [CONF_DEFAULT_DISTRICTS]= [CONF_DEFAULT_GEAR_CAPABILITIES]= [CONF_DEFAULT_GEAR_SIZE]= [CONF_DISTRICT_FIRST_UID]= [CONF_DISTRICT_MAPPINGS]= [CONF_DOMAIN]= [CONF_ENABLE_HA]= [CONF_ENABLE_SNI_PROXY]= [CONF_FORWARD_DNS]= [CONF_FUSE_EXTRA_REPO]= [CONF_HOSTS_DOMAIN]= [CONF_HOSTS_DOMAIN_KEYFILE]= [CONF_HTTP_PROXY]= [CONF_HTTPS_PROXY]= [CONF_IDLE_INTERVAL]= [CONF_INSTALL_COMPONENTS]= [CONF_INSTALL_METHOD]= [CONF_INTERFACE]= [CONF_ISOLATE_GEARS]= [CONF_JBOSSEAP_EXTRA_REPO]= [CONF_JBOSSEAP_VERSION]= [CONF_JBOSSEWS_EXTRA_REPO]= [CONF_JBOSS_REPO_BASE]= [CONF_KEEP_HOSTNAME]= [CONF_KEEP_NAMESERVERS]= [CONF_MCOLLECTIVE_PASSWORD]= [CONF_MCOLLECTIVE_USER]= [CONF_METAPKGS]= [CONF_METRICS_INTERVAL]= [CONF_MONGODB_ADMIN_PASSWORD]= [CONF_MONGODB_ADMIN_USER]= [CONF_MONGODB_BROKER_PASSWORD]= [CONF_MONGODB_BROKER_USER]= [CONF_MONGODB_KEY]= [CONF_MONGODB_NAME]= [CONF_MONGODB_PASSWORD]= [CONF_MONGODB_REPLSET]= [CONF_NAMED_ENTRIES]= [CONF_NAMED_HOSTNAME]= [CONF_NAMED_IP_ADDR]= [CONF_NO_DATASTORE_AUTH_FOR_LOCALHOST]= [CONF_NODE_APACHE_FRONTEND]= [CONF_NODE_HOSTNAME]= [CONF_NODE_HOST_TYPE]= [CONF_NODE_IP_ADDR]= [CONF_NODE_LOG_CONTEXT]= [CONF_NODE_PROFILE]= [CONF_NODE_PROFILE_NAME]= [CONF_NO_NTP]= [CONF_NO_SCRAMBLE]= [CONF_OPENSHIFT_PASSWORD]= [CONF_OPENSHIFT_PASSWORD1]= [CONF_OPENSHIFT_USER]= [CONF_OPENSHIFT_USER1]= [CONF_OPTIONAL_REPO]= [CONF_OSE_ERRATA_BASE]= [CONF_OSE_EXTRA_REPO_BASE]= [CONF_OSE_REPO_BASE]= [CONF_PORTS_PER_GEAR]= [CONF_PROFILE_NAME]= [CONF_REPOS_BASE]= [CONF_RHEL_EXTRA_REPO]= [CONF_RHEL_OPTIONAL_REPO]= [CONF_RHEL_REPO]= [CONF_RHN_PASS]= [CONF_RHN_REG_ACTKEY]= [CONF_RHN_REG_NAME]= [CONF_RHN_REG_OPTS]= [CONF_RHN_REG_PASS]= [CONF_RHN_USER]= [CONF_RHSCL_EXTRA_REPO]= [CONF_RHSCL_REPO_BASE]= [CONF_ROUTER]= [CONF_ROUTER_HOSTNAME]= [CONF_ROUTING_PLUGIN]= [CONF_ROUTING_PLUGIN_PASS]= [CONF_ROUTING_PLUGIN_USER]= [CONF_SM_REG_NAME]= [CONF_SM_REG_PASS]= [CONF_SM_REG_POOL]= [CONF_SNI_FIRST_PORT]= [CONF_SNI_PROXY_PORTS]= [CONF_SYSLOG]= [CONF_VALID_GEAR_SIZES]= [CONF_YUM_EXCLUDE_PKGS]= )

  set +x # don't log passwords
  local setting
  for setting in "${!CONF_@}"
  do
    if [[ -z "${valid_settings[$setting]+x}" ]]
    then
      if is_true "$abort_on_unrecognized_settings"
      then
        abort_install "Unrecognized setting: $setting"
      else
        echo "WARNING: Unrecognized setting: $setting"
      fi
    else
      # The setting is recognized, so check whether a non-empty value is given.
      [[ -n "${!setting}" ]] || abort_install "Setting is assigned an empty value: $setting"
    fi
  done
  set -x

  # By default, we run do_all_actions, which performs all the steps of
  # a normal installation.
  actions="${CONF_ACTIONS:-do_all_actions}"

  # Following are the different components that can be installed:
  local components='broker node named activemq datastore router'

  # By default, each component is _not_ installed.
  local component
  for component in $components
  do
    eval "$component() { false; }"
  done

  # But any or all components may be explicity enabled.
  local component
  for component in ${CONF_INSTALL_COMPONENTS//,/ }
  do
    case "$component" in
      (broker|node|named|activemq|datastore|router) ;;
      (*) abort_install "Unrecognized component: $component" ;;
    esac
    eval "$component() { :; }"
  done

  # If nothing is explicitly enabled, enable everything.
  local installing_something=0
  # We want word-splitting on $components.
  for component in $components
  do
    if "$component"
    then
      installing_something=1
      break
    fi
  done
  if [[ "$installing_something" = 0 ]]
  then
    for component in ${components//router} # default: all but router
    do
      eval "$component() { :; }"
    done
  fi

  if router
  then
    if broker || node
    then abort_install 'The router component cannot be installed on the same host as the broker or node components.'
    fi
  fi

  # Following are some settings used in subsequent steps.

  # The list of packages to install.
  cartridges="${CONF_CARTRIDGES:-standard}"

  jbosseap_version="${CONF_JBOSSEAP_VERSION:-6.3}"
  # Check jbosseap_version for validity
  case "$jbosseap_version" in
      (6.3|6.4)
          jbosseap_version="$jbosseap_version"
          jbosseap_yumvalidator_role="node-eap-$jbosseap_version"
          ;;
      (current|6)
          jbosseap_version="6"
          jbosseap_yumvalidator_role='node-eap'
          ;;
    (*) abort_install "Unrecognized JBoss EAP channel version: $CONF_JBOSSEAP_VERSION" ;;
  esac

  named_entries="${CONF_NAMED_ENTRIES-}"

  # The domain name for the OpenShift Enterprise installation.
  domain="${CONF_DOMAIN:-example.com}"
  hosts_domain="${CONF_HOSTS_DOMAIN:-$domain}"
  hosts_domain_keyfile="${CONF_HOSTS_DOMAIN_KEYFILE:-/var/named/${hosts_domain}.key}"

  keep_nameservers="${CONF_KEEP_NAMESERVERS:-false}"
  keep_hostname="${CONF_KEEP_HOSTNAME:-false}"

  # Hostnames to use for the components (could all resolve to same host).
  broker_hostname=$(ensure_domain "${CONF_BROKER_HOSTNAME:-broker}" "$hosts_domain")
  node_hostname=$(ensure_domain "${CONF_NODE_HOSTNAME:-node}" "$hosts_domain")
  named_hostname=$(ensure_domain "${CONF_NAMED_HOSTNAME:-ns1}" "$hosts_domain")
  activemq_hostname=$(ensure_domain "${CONF_ACTIVEMQ_HOSTNAME:-activemq}" "$hosts_domain")
  datastore_hostname=$(ensure_domain "${CONF_DATASTORE_HOSTNAME:-datastore}" "$hosts_domain")
  router_hostname=$(ensure_domain "${CONF_ROUTER_HOSTNAME:-www}" "$domain")

  # The hostname name for this host.
  # Note: If this host is, e.g., both a broker and a datastore, we want
  # to go with the broker hostname and not the datastore hostname.
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
  elif router
  then hostname="$router_hostname"
  fi

  # Grab the IP address set during installation.
  cur_ip_addr="$(/sbin/ip addr show | awk '/inet .*global/ { split($2,a,"/"); print a[1]; }' | head -1)"

  # Unless otherwise specified, the broker is assumed to be the current
  # host.
  broker_ip_addr="${CONF_BROKER_IP_ADDR:-$cur_ip_addr}"

  # Unless otherwise specified, the node is assumed to be the current
  # host.
  node_ip_addr="${CONF_NODE_IP_ADDR:-$cur_ip_addr}"

  # There are no defaults for these.  Customers should be using
  # subscriptions via RHN.  Internally, we use private systems.
  rhel_repo="${CONF_RHEL_REPO%/}"
  rhel_extra_repo="${CONF_RHEL_EXTRA_REPO%/}"
  jboss_repo_base="${CONF_JBOSS_REPO_BASE%/}"
  jbosseap_extra_repo="${CONF_JBOSSEAP_EXTRA_REPO%/}"
  jbossews_extra_repo="${CONF_JBOSSEWS_EXTRA_REPO%/}"
  fuse_extra_repo="${CONF_FUSE_EXTRA_REPO%/}"
  amq_extra_repo="${CONF_AMQ_EXTRA_REPO%/}"
  rhscl_repo_base="${CONF_RHSCL_REPO_BASE%/}"
  rhscl_extra_repo="${CONF_RHSCL_EXTRA_REPO%/}"
  enable_optional_repo="${CONF_OPTIONAL_REPO:-false}"
  rhel_optional_repo="${CONF_RHEL_OPTIONAL_REPO%/}"
  yum_exclude_pkgs="${CONF_YUM_EXCLUDE_PKGS-}"
  # Where to find the OpenShift repositories; just the base part before
  # splitting out into Infrastructure/Node/etc.
  ose_repo_base="${CONF_OSE_REPO_BASE:-${CONF_REPOS_BASE-}}"
  ose_repo_base="${ose_repo_base%/}"

  # By default, do not use CDN layout for Yum repositories, unless
  # CONF_CDN_REPO_BASE is set.
  cdn_layout="${CONF_CDN_REPO_BASE-}"
  cdn_repo_base="${CONF_CDN_REPO_BASE%/}"
  if [[ -n "$cdn_repo_base" ]]
  then
    rhel_repo="${rhel_repo:-$cdn_repo_base/os}"
    jboss_repo_base="${jboss_repo_base:-$cdn_repo_base}"
    rhscl_repo_base="${rhscl_repo_base:-$cdn_repo_base}"
    rhel_optional_repo="${rhel_optional_repo:-${cdn_repo_base}/optional/os}"
    ose_repo_base="${ose_repo_base:-$cdn_repo_base}"
    if [[ "$cdn_repo_base" = "$ose_repo_base" ]]
    then # same repo layout
      cdn_layout=1  # use the CDN layout for OpenShift yum repos
    fi
  elif [[ "$rhel_repo" = "${ose_repo_base}/os" ]]
  then # OSE same repo base as RHEL?
    cdn_layout=1  # use the CDN layout for OpenShift yum repos
  fi
  ose_extra_repo_base="${CONF_OSE_EXTRA_REPO_BASE%/}"
  rhscl_repo_base="${rhscl_repo_base:-${rhel_repo%/os}}"

  install_method="${CONF_INSTALL_METHOD:-none}"
  # There is no need to waste time checking both subscription plugins
  # if using one is explicitly enabled.
  disable_plugin=
  case "$install_method" in
    (rhsm)
      disable_plugin='--disableplugin=rhnplugin'
      sm_reg_pool="${CONF_SM_REG_POOL-}"
    ;;
    (rhn)
      disable_plugin='--disableplugin=subscription-manager'
      rhn_reg_actkey="${CONF_RHN_REG_ACTKEY-}"
    ;;
    (yum)
      # We could do the same for "yum" method, but that would be more likely
      # to surprise someone.
      #disable_plugin='--disableplugin=subscription-manager --disableplugin=rhnplugin'
    ;;
  esac

  # Note: we use the rhn_user, rhn_pass, rhn_reg_opts, and rhn_profile_name
  # variables for both RHN and RHSM.
  if [[ "$install_method" =~ rhn|rhsm ]]
  then
    rhn_reg_opts="${CONF_RHN_REG_OPTS-}"

    # Check for subscription parameters under all previously used setting
    # names.
    rhn_user="${CONF_RHN_USER:-${CONF_SM_REG_NAME:-${CONF_RHN_REG_NAME-}}}"
    # Don't log password.
    set +x
    rhn_pass="${CONF_RHN_PASS:-${CONF_SM_REG_PASS:-${CONF_RHN_REG_PASS-}}}"
    if [[ -n "$rhn_user" && -n "$rhn_pass" ]]
    then rhn_creds_provided='true'
    else rhn_creds_provided='false'
    fi
    set -x

    # How to label the system when subscribing.
    rhn_profile_name="${CONF_PROFILE_NAME:-OpenShift-${hostname}-${cur_ip_addr}-${CONF_RHN_USER}}"
  fi

  # Install and enable the ntpd daemon.
  if is_true "${CONF_NO_NTP:-false}"
  then enable_ntp='false'
  else enable_ntp='true'
  fi


  node_apache_frontend="${CONF_NODE_APACHE_FRONTEND:-vhost}"

  # Unless otherwise specified, the named service, data store, and
  # ActiveMQ service are assumed to be the current host if we are
  # installing the component now or the broker host otherwise.
  if named
  then named_ip_addr="${CONF_NAMED_IP_ADDR:-$cur_ip_addr}"
  else named_ip_addr="${CONF_NAMED_IP_ADDR:-$broker_ip_addr}"
  fi

  # The nameservers to which named on the broker will forward requests.
  # This should be a list of IP addresses with a semicolon after each.
  nameservers="$(awk '/nameserver/ { printf "%s; ", $2 }' /etc/resolv.conf)"

  # Configure BIND to enable DNS forwarding.
  enable_dns_forwarding="${CONF_FORWARD_DNS:-false}"

  # Log the specified components to syslog.
  log_to_syslog="${CONF_SYSLOG-}"

  # Main interface to configure
  interface="${CONF_INTERFACE:-eth0}"

  # For Kerberos:
  bind_krb_keytab="${CONF_BIND_KRB_KEYTAB-}"
  bind_krb_principal="${CONF_BIND_KRB_PRINCIPAL-}"
  # For key-based authentication:
  bind_key="${CONF_BIND_KEY-}"
  bind_keyalgorithm="${CONF_BIND_KEYALGORITHM:-HMAC-SHA256}"
  bind_keysize="${CONF_BIND_KEYSIZE:-256}"

  local s
  for s in valid_gear_sizes default_gear_capabilities default_gear_size
  do eval "isset_${s}() { false; }"
  done

  # Set $valid_gear_sizes to $CONF_VALID_GEAR_SIZES
  [[ -n "${CONF_VALID_GEAR_SIZES:+x}" ]] && isset_valid_gear_sizes() { :; }
  broker && valid_gear_sizes="${CONF_VALID_GEAR_SIZES:-small}"

  # Set $default_gear_capabilities to $CONF_DEFAULT_GEAR_CAPABILITIES
  [[ -n "${CONF_DEFAULT_GEAR_CAPABILITIES:+x}" ]] && isset_default_gear_capabilities() { :; }
  broker && default_gear_capabilities="${CONF_DEFAULT_GEAR_CAPABILITIES:-$valid_gear_sizes}"

  # Set $default_gear_size to $CONF_DEFAULT_GEAR_SIZE
  [[ -n "${CONF_DEFAULT_GEAR_SIZE:+x}" ]] && isset_default_gear_size() { :; }
  broker && default_gear_size="${CONF_DEFAULT_GEAR_SIZE:-${valid_gear_sizes%%,*}}"

  node_profile="${CONF_NODE_PROFILE:-small}"
  node && node_profile_name="${CONF_NODE_PROFILE_NAME:-$node_profile}"
  node && node_host_type="${CONF_NODE_HOST_TYPE:-m3.xlarge}"
  # determine node port and UID settings
  local def_ports=5; is_xpaas && def_ports=15
  ports_per_gear="${CONF_PORTS_PER_GEAR:-$def_ports}"
  district_first_uid="${CONF_DISTRICT_FIRST_UID:-1000}"
  let "district_uid_pool=30000/$ports_per_gear"
  let "district_last_uid=${district_first_uid}+${district_uid_pool}-1"
  isolate_gears="${CONF_ISOLATE_GEARS:-true}"
  # determine node sni proxy settings
  local def_enable="false"; is_xpaas && def_enable="true"
  enable_sni_proxy="${CONF_ENABLE_SNI_PROXY:-$def_enable}"
  sni_first_port="${CONF_SNI_FIRST_PORT:-2303}"
  def_ports=5; is_xpaas && def_ports=10
  sni_proxy_ports="${CONF_SNI_PROXY_PORTS:-$def_ports}"
  let "sni_last_port=$sni_first_port+$sni_proxy_ports-1"

  idle_interval="${CONF_IDLE_INTERVAL-}"
  node_log_context="${CONF_NODE_LOG_CONTEXT:-false}"
  metrics_interval="${CONF_METRICS_INTERVAL-}"

  # Set $default_districts to $CONF_DEFAULT_DISTRICTS
  broker && default_districts="${CONF_DEFAULT_DISTRICTS:-true}"

  # Set $district_mappings to $CONF_DISTRICT_MAPPINGS
  broker && district_mappings="${CONF_DISTRICT_MAPPINGS-}"

  local randomized

  # Generate a random salt for the broker authentication.
  randomized=$(openssl rand -base64 20)
  broker && broker_auth_salt="${CONF_BROKER_AUTH_SALT:-$randomized}"

  # Generate a random session secret for broker sessions.
  randomized=$(openssl rand -hex 64)
  broker && broker_session_secret="${CONF_BROKER_SESSION_SECRET:-$randomized}"

  # Generate a random session secret for console sessions.
  randomized=$(openssl rand -hex 64)
  broker && console_session_secret="${CONF_CONSOLE_SESSION_SECRET:-$randomized}"

  # Generate a new 2048 bit RSA keypair for broker authentication if
  # CONF_BROKER_AUTH_PRIV_KEY not set
  broker && broker_auth_priv_key="${CONF_BROKER_AUTH_PRIV_KEY:-$(openssl genrsa 2048)}"

  # If no list of replicants is provided, assume there is only one datastore host.
  datastore_replicants="${CONF_DATASTORE_REPLICANTS:-${datastore_hostname}:27017}"
  # For each replicant that does not have an explicit port number
  # specified, append :27017 to its host name.
  datastore_replicants="$( for repl in ${datastore_replicants//,/ }
                           do
                             [[ "$repl" =~ : ]] || repl="${repl}:27017"
                             printf ',%s' "$repl"
                           done)"
  datastore_replicants="${datastore_replicants:1}"


  # If no list of replicants is provided, assume there is only one
  # ActiveMQ host.
  activemq_replicants="${CONF_ACTIVEMQ_REPLICANTS:-$activemq_hostname}"

  # Set default passwords
  #
  #   If no_scramble/CONF_NO_SCRAMBLE is true, then passwords will
  #   not be randomized.
  no_scramble="${CONF_NO_SCRAMBLE:-false}"

  #   This is the admin password for the ActiveMQ admin console, which
  #   is not needed by OpenShift but might be useful in troubleshooting.
  randomized=$(openssl rand -base64 20)
  activemq && assign_pass activemq_admin_password "${randomized//[![:alnum:]]}" CONF_ACTIVEMQ_ADMIN_PASSWORD

  #   This is the password for the ActiveMQ amq user, which is used by
  #   ActiveMQ broker replicants to communicate with one another.  The
  #   amq user is enabled only if replicants are specified using the
  #   activemq_replicants.setting
  activemq && assign_pass activemq_amq_user_password password CONF_ACTIVEMQ_AMQ_USER_PASSWORD

  #   This is the user and password shared between broker and node for
  #   communicating over the mcollective topic channels in ActiveMQ.
  #   Must be the same on all broker and node hosts.
  (broker || node || activemq) && mcollective_user="${CONF_MCOLLECTIVE_USER:-mcollective}"
  (broker || node || activemq) && assign_pass mcollective_password marionette CONF_MCOLLECTIVE_PASSWORD

  # Enable authentication for MongoDB.
  if is_true "${CONF_NO_DATASTORE_AUTH_FOR_LOCALHOST:-false}"
  then enable_datastore_auth=false
  else enable_datastore_auth=true
  fi

  #   These are the username and password of the administrative user
  #   that will be created in the MongoDB datastore. These credentials
  #   are not used by in this script or by OpenShift, but an
  #   administrative user must be added to MongoDB in order for it to
  #   enforce authentication.
  datastore && mongodb_admin_user="${CONF_MONGODB_ADMIN_USER:-admin}"
  datastore && tmpvar=${CONF_MONGODB_ADMIN_PASSWORD:-${CONF_MONGODB_PASSWORD-}}
  datastore &&  assign_pass mongodb_admin_password mongopass tmpvar

  #   These are the username and password of the normal user that will
  #   be created for the broker to connect to the MongoDB datastore. The
  #   broker application's MongoDB plugin is also configured with these
  #   values.
  (datastore || broker) && mongodb_broker_user="${CONF_MONGODB_BROKER_USER:-openshift}"
  (datastore || broker) && tmpvar="${CONF_MONGODB_BROKER_PASSWORD:-${CONF_MONGODB_PASSWORD-}}"
  (datastore || broker) && assign_pass mongodb_broker_password mongopass tmpvar

  #   In replicated setup, this is the key that slaves will use to
  #   authenticate with the master.
  datastore && assign_pass mongodb_key OSEnterprise CONF_MONGODB_KEY

  #   In replicated setup, this is the name of the replica set.
  mongodb_replset="${CONF_MONGODB_REPLSET:-ose}"

  #   This is the name of the database in MongoDB in which the broker
  #   will store data.
  mongodb_name="${CONF_MONGODB_NAME:-openshift_broker}"

  #   This user and password are entered in the /etc/openshift/htpasswd
  #   file as a demo/test user. You will likely want to remove it after
  #   installation (or just use a different auth method).
  broker && openshift_user1="${CONF_OPENSHIFT_USER1:-demo}"
  broker && assign_pass openshift_password1 changeme CONF_OPENSHIFT_PASSWORD1

  enable_ha="${CONF_ENABLE_HA-false}"
  router="${CONF_ROUTER-}"

  # auth info for the topic from the sample routing SPI plugin
  local default_enable_routing_plugin=false
  broker && [[ -n "$router" ]] && default_enable_routing_plugin=true
  enable_routing_plugin="${CONF_ROUTING_PLUGIN:-$default_enable_routing_plugin}"
  routing_plugin_user="${CONF_ROUTING_PLUGIN_USER:-routinginfo}"
  assign_pass routing_plugin_pass routinginfopasswd CONF_ROUTING_PLUGIN_PASS

  broker_krb_service_name="${CONF_BROKER_KRB_SERVICE_NAME-}"
  broker_krb_auth_realms="${CONF_BROKER_KRB_AUTH_REALMS-}"

  outgoing_http_proxy="${CONF_HTTP_PROXY-}"
  outgoing_https_proxy="${CONF_HTTPS_PROXY-}"

  # cartridge dependency metapackages
  metapkgs="${CONF_METAPKGS:-recommended}"

  # need to know the list of cartridges in various places.
  parse_cartridges
}


########################################################################
#
# These top-level steps also emit cues for automation to track progress.
# Please don't change output wording arbitrarily.

init_message()
{
  echo_installation_intentions
  [[ "$environment" = ks ]] && configure_console_msg
  return 0
}

validate_preflight()
{
  echo 'OpenShift: Begin preflight validation.'
  local preflight_failure=

  # Test that this isn't RHEL < 6 or Fedora
  if ! grep -q 'Enterprise.* 6' /etc/redhat-release
  then
    echo 'OpenShift: This process needs to begin with Enterprise Linux 6 installed.'
    preflight_failure=1
  fi

  # Test that SELinux is at least present and not Disabled
  if ! command -v getenforce || ! [[ "$(getenforce)" =~ Enforcing|Permissive ]]
  then
    echo 'OpenShift: SELinux needs to be installed and enabled.'
    preflight_failure=1
  fi

  # Test that rpm/yum exists and isn't totally broken
  if ! command -v rpm || ! command -v yum
  then
    echo 'OpenShift: rpm and yum must be installed.'
    preflight_failure=1
  fi
  if ! rpm -q rpm yum
  then
    echo 'OpenShift: rpm command failed; there may be a problem with the RPM DB.'
    preflight_failure=1
  fi

  # test that subscription parameters are available if needed
  if [[ "$install_method" = rhn ]]
  then
    # Check whether we are already registered with RHN and already have
    # ose-2.2 channels added.  If we are not, we will need RHN
    # credentials so that we can register and add channels ourselves.
    #
    # Note: With RHN, we need credentials both for registration and
    # adding channels.
    if ! [[ -f '/etc/sysconfig/rhn/systemid' ]] || ! rhn-channel -l | grep -q '^rhel-x86_64-server-6-ose-2.2-\(node\|infrastructure\)'
    then
      # Don't log password.
      set +x
      if [[ -z "$rhn_user" || -z "$rhn_pass" ]]
      then
        echo 'OpenShift: Install method rhn requires an RHN user and password.'
        preflight_failure=1
      fi
      set -x
    fi
  fi

  if [[ "$install_method" = rhsm ]]
  then
    # Check whether we are already registered with RHSM.  If we are not,
    # we will need credentials so that we can register ourselves.
    #
    # Note: With RHSM, we need credentials for registration but not for
    # adding channels.
    if ! subscription-manager identity | grep -q 'identity is:'
    then
      # Don't log password.
      set +x
      if [[ -z "$rhn_user" || -z "$rhn_pass" ]]
      then
        echo 'OpenShift: Install method rhsm requires an RHN user and password.'
        preflight_failure=1
      fi
      set -x
    fi

    # If we are not given a pool id, we will not be able to attach any
    # pools, so make sure we already have access to the ose-2.2 repos,
    # and we also need to make sure that we have NOT been given RHN
    # credentials because that would cause configure_rhsm_channels to
    # re-register and lose access to those repos.
    #
    # In the pipeline below, tac is a hack to make sure that
    # subscription-manager gets to write all of its plentiful output
    # before grep closes the pipeline.  Without it, we will get
    # a harmless but possibly alarming "Broken pipe" error message.
    if [[ -z "$sm_reg_pool" ]] &&
        ( [[ -n "$rhn_user" && -n "$rhn_pass" ]] ||
          ! subscription-manager repos | tac | grep -q '\<rhel-6-server-ose-2.2-\(infra\|node\)-rpms$' )
    then
      echo 'OpenShift: Install method rhsm requires a poolid.'
      preflight_failure=1
    fi
  fi

  if [[ "$install_method" = yum && -z "$ose_repo_base" ]]
  then
    echo 'OpenShift: Install method yum requires providing URLs for at least OpenShift repos.'
    preflight_failure=1
  fi

  # Test that known problematic RPMs aren't present
  # ... ?

  [[ -n "$preflight_failure" ]] && abort_install
  echo 'OpenShift: Completed preflight validation.'
}

install_rpms()
{
  echo 'OpenShift: Begin installing RPMs.'
  # We often rely on the latest SELinux policy and other updates.
  echo 'OpenShift: yum update'
  # We want word-splitting (including null-argument removal) on $disable_plugin.
  yum $disable_plugin clean all

  local count=0
  while true
  do
    yum $disable_plugin update -y && break
    if [[ "$count" -gt 3 ]]
    then abort_install
    fi
    let count+=1
  done

  # Install a few packages missing from a minimal RHEL install required by the
  # installer script itself.
  yum_install_or_exit ntp ntpdate wget

  # install what we need for various components
  named && install_named_pkgs
  datastore && install_datastore_pkgs
  activemq && install_activemq_pkgs
  broker && install_broker_pkgs
  node && install_node_pkgs
  node && install_cartridges
  node && remove_abrt_addon_python
  broker && install_rhc_pkg
  router && install_router_pkgs
  echo 'OpenShift: Completed installing RPMs.'
}

configure_host()
{
  echo 'OpenShift: Begin configuring host.'
  is_true "$enable_ntp" && synchronize_clock
  # Note: configure_named must run before configure_controller if we are
  # installing both named and broker on the same host.
  named && configure_named
  configure_network
  is_false "$keep_nameservers" && configure_dns_resolution
  is_false "$keep_hostname" && configure_hostname

  # Minimize grub timeout on startup.
  set_conf '/etc/grub.conf' timeout 1

  # Remove VirtualHost from the default httpd ssl.conf to prevent a warning.
  if broker || node
  then sed -i '/VirtualHost/,/VirtualHost/ d' '/etc/httpd/conf.d/ssl.conf'
  fi

  # Reset the firewall to disable lokkit and initialise iptables configuration.
  configure_firewall

  # All hosts should enable SSH access.
  firewall_allow[ssh]='tcp:22'
  configure_firewall_add_rules
  echo 'OpenShift: Completed configuring host.'
}

configure_firewall()
{
  # Disable lokkit.
  local conf='/etc/sysconfig/system-config-firewall'
  [[ -e "$conf" && "$(< "$conf")" != --disabled ]] && mv "$conf" "${conf}.bak"
  echo '--disabled' > "$conf"

  # Configure iptables.
cat > '/etc/sysconfig/iptables' <<'EOF'
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
-A INPUT -p icmp -j ACCEPT
-A INPUT -i lo -j ACCEPT
-A INPUT -j REJECT --reject-with icmp-host-prohibited
-A FORWARD -j REJECT --reject-with icmp-host-prohibited
COMMIT
EOF

  # Load the configuration on reboot.
  chkconfig iptables on
}

# Note: This function must be run after configure_firewall.
configure_firewall_add_rules()
{
  local rules=
  local port
  local prot
  local rule
  local svc
  for svc in "${!firewall_allow[@]}"
  do
    rules+="$(
      for rule in ${firewall_allow[$svc]//,/ }
      do
        prot="${rule%%:*}"
        port="${rule#*:}"
        printf ' \\\n-A INPUT -m state --state NEW -m %s -p %s --dport %s -j ACCEPT' "$prot" "$prot" "$port"
      done
    )"
    unset firewall_allow[$svc]
  done

  # Insert the rules specified by ${firewall_allow[@]} before the first
  # REJECT rule in the INPUT chain.
  sed -i -e $'/-A INPUT -j REJECT/i \\\n'"${rules:3}" '/etc/sysconfig/iptables'
}

configure_gear_isolation_firewall()
{
  is_true "$isolate_gears" && oo-gear-firewall -i conf -b "$district_first_uid" -e "$district_last_uid"
}

configure_openshift()
{
  echo 'OpenShift: Begin configuring OpenShift.'

  # Prepare services that the broker and node depend on.
  datastore && configure_datastore
  activemq && configure_activemq
  broker && configure_mcollective_for_activemq_on_broker
  node && configure_mcollective_for_activemq_on_node

  # Configure the broker and/or node.
  broker && enable_services_on_broker
  node && enable_services_on_node
  node && configure_pam_on_node
  node && configure_cgroups_on_node
  node && configure_quotas_on_node
  broker && configure_selinux_policy_on_broker
  node && configure_sysctl_on_node
  node && configure_sshd_on_node
  node && configure_idler_on_node
  broker && configure_controller
  broker && configure_messaging_plugin
  broker && configure_dns_plugin
  broker && configure_httpd_auth
  broker && configure_routing_plugin
  broker && configure_broker_ssl_cert
  broker && configure_access_keys_on_broker
  broker && configure_rhc
  { node || broker; } && configure_outgoing_http_proxy

  node && configure_port_proxy
  node && configure_gears
  node && configure_node
  node && configure_selinux_policy_on_node # must run after configure_node
  node && configure_wildcard_ssl_cert_on_node
  node && update_openshift_facts_on_node

  node && broker && fix_broker_routing

  { broker || router; } && configure_routing_daemon
  router && configure_router

  configure_firewall_add_rules
  node && configure_gear_isolation_firewall

  sysctl -p || :
  restorecon -rv '/etc/openshift'

  PASSWORDS_TO_DISPLAY=true
  RESTART_NEEDED=true
  echo 'OpenShift: Completed configuring OpenShift.'
}

restart_services()
{
  echo 'OpenShift: Begin restarting services.'

  service iptables restart

  # named is already started in configure_named.
  named && service named restart

  # mongod is already started in configure_datastore.
  node && service cgconfig restart
  node && service cgred restart
  service network restart
  { node || broker; } && service sshd restart
  service ntpd restart
  node && service messagebus restart
  node && service ruby193-mcollective stop
  activemq && service activemq restart
  node && service ruby193-mcollective start
  { node || broker; } && service httpd restart
  broker && service openshift-broker restart
  broker && service openshift-console restart
  node && service oddjobd restart
  node && service openshift-iptables-port-proxy restart
  node && service openshift-node-web-proxy restart
  node && is_true "$enable_sni_proxy" && service openshift-sni-proxy restart
  node && service openshift-watchman restart

  if router && [[ "$router" = nginx ]]
  then
    service openshift-routing-daemon restart

    # Don't try to start nginx unless /etc/pki/tls/certs/node.example.com.crt
    # and /etc/pki/tls/private/node.example.com.key exist because nginx will
    # fail to start without them.
    #
    # These files should be copies of /etc/pki/tls/certs/localhost.crt and
    # /etc/pki/tls/private/localhost.key, respectively, from a node host.
    if [[ -e '/etc/pki/tls/certs/node.example.com.crt' &&
          -e '/etc/pki/tls/private/node.example.com.key' ]]
    then
      service nginx16-nginx restart
    fi
  fi

  # Ensure OpenShift facts are updated.
  node && '/etc/cron.minutely/openshift-facts'

  echo 'OpenShift: Completed restarting services.'
}

run_diagnostics()
{
  echo 'OpenShift: Begin running oo-diagnostics.'
  date '+%Y-%m-%d-%H:%M:%S'
  # prepending the output of oo-diagnostics breaks the ansi color coding
  # remove all ansi escape sequences from oo-diagnostics output
  oo-diagnostics |& sed -u -e 's/\x1B\[[0-9;]*[JKmsu]//g' -e 's/^/OpenShift: oo-diagnostics output - /g'
  date '+%Y-%m-%d-%H:%M:%S'
  echo 'OpenShift: Completed running oo-diagnostics.'
}

reboot_after()
{
  echo 'OpenShift: Rebooting after install.'
  reboot
}

configure_districts()
{
  echo 'OpenShift: Configuring districts.'
  date '+%Y-%m-%d-%H:%M:%S'

  local restart="$RESTART_NEEDED"
  if is_true "$default_districts"
  then
    local p
    for p in ${valid_gear_sizes//,/ }
    do
      is_xpaas "$p" && configure_messaging_plugin 15  # xpaas profile requires more ports
      oo-admin-ctl-district -p "$p" -n "default-$p" -c add-node --available |& sed -e 's/^\(Error\)/OpenShift: oo-admin-ctl-district - \1/g'
      is_xpaas "$p" && configure_messaging_plugin  # back to default
    done
  else
    local i
    local profile
    local firstnode
    local nodes
    local district
    local mapping
    for mapping in ${district_mappings//;/ }
    do
      district="${mapping%%:*}"
      nodes="${mapping#*:}"
      firstnode="${nodes//,*/}"
      # Query the node for the node profile via MCollective.
      profile=
      for i in {1..10}
      do
        profile="$(oo-ruby -e "require 'mcollective'; include MCollective::RPC; mc=rpcclient('rpcutil'); mc.progress=false; result=mc.custom_request('get_fact', {:fact => 'node_profile'}, ['${firstnode}'], {'identity' => '${firstnode}'}); if not result.empty?;  value=result.first.results[:data][:value]; if not value.nil? and not value.empty?; puts value; exit 0; end; end; exit 1" 2>/dev/null)" \
         && break
        sleep 10
      done
      if [[ -n "$profile" ]]
      then
        echo "OpenShift: Adding nodes: $nodes with profile: $profile to district: $district."
        is_xpaas "$profile" && configure_messaging_plugin 15  # xpaas profile requires more ports
        oo-admin-ctl-district -p "$profile" -n "$district" -c add-node -i "$nodes" |& sed -e 's/^\(Error\)/OpenShift: oo-admin-ctl-district - \1/g'
        is_xpaas "$profile" && configure_messaging_plugin  # back to default
      else
        echo "OpenShift: Could not determine gear profile for nodes: ${nodes}, cannot add to district $district"
      fi
    done
  fi
  # Configuring districts should not normally require a service restart.
  RESTART_NEEDED="$restart"

  date '+%Y-%m-%d-%H:%M:%S'
  echo 'OpenShift: Completed configuring districts.'
}

post_deploy()
{
  echo 'OpenShift: Begin post deployment steps.'

  if broker
  then
    if isset_valid_gear_sizes || isset_default_gear_capabilities || isset_default_gear_size
    then
      update_controller_gear_size_configs
      RESTART_NEEDED=true
    fi

    "$RESTART_NEEDED" && restart_services && RESTART_COMPLETED=true

    # Import cartridges.
    oo-admin-ctl-cartridge -c import-node --activate --obsolete

    configure_districts
  fi

  node && install_rsync_pub_key

  echo 'OpenShift: Completed post deployment steps.'
}

do_all_actions()
{
  # Avoid adding or removing these top-level actions.  oo-install invokes these
  # individually in separate phases, so they should not assume the others ran
  # previously in the same invocation.
  init_message
  validate_preflight
  configure_repos
  install_rpms
  configure_host
  configure_openshift
  echo 'Installation and configuration complete.'
}

########################################################################


# This line to be modified by make per environment:
environment=sh
case "$environment" in
ks)
  # parse_kernel_cmdline is only needed for kickstart and not if this %post
  # section is extracted and executed on a running system.
  parse_kernel_cmdline
  ;;
vm)
  # no args to parse; they are directly inserted by make.
  ;;
*)
  # parse_cmdline is only needed for shell scripts generated by extracting
  # this %post section.
  parse_cmdline "$@"
  ;;
esac

declare -A passwords
PASSWORDS_TO_DISPLAY=false
RESTART_NEEDED=false
RESTART_COMPLETED=false

# Make sure /sbin and /usr/sbin are in PATH
for admin_path in /sbin /usr/sbin
do
  if [[ ":$PATH:" != *:"$admin_path":* ]]
  then PATH="${PATH}:${admin_path}"
  fi
done

# Initialize associative array to which firewall rules can be added (see
# configure_firewall_add_rules).  This must be declared here for scoping.
declare -A firewall_allow

set_defaults

date '+%Y-%m-%d-%H:%M:%S'
for action in ${actions//,/ }
do
  [[ "$(type -t "$action")" = function ]] || abort_install "Invalid action: $action"
  "$action"
done
date '+%Y-%m-%d-%H:%M:%S'

# In the case of a kickstart, some services will not be able to start, and the
# host will automatically reboot anyway after the kickstart script completes.
[[ "$environment" = ks ]] && RESTART_NEEDED=false

"$RESTART_NEEDED" && ! "$RESTART_COMPLETED" && restart_services

"$PASSWORDS_TO_DISPLAY" && display_passwords

exit 0

