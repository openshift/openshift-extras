# This script configures a single host with OpenShift components. It may
# be used either as a RHEL6 kickstart script, or the %post section may
# be extracted and run directly to install on top of an installed RHEL6
# image. When running the %post outside kickstart, a reboot is required
# afterward.
#
# If this script aborts due to an inability to install packages (the most
# common failure), it should be safe to re-run once you've resolved the
# problem (i.e. either manually fix configuration and run with
# INSTALL_METHOD=none, or unregister / remove all repos and start over).
# Once package installation completes and configuration begins, aborts
# are unlikely; but in the event that one occurs, re-running could
# introduce misconfigurations as configure steps do not all include
# enough intelligence to be repeatable.
#
# While this script serves as a good example script for installing a
# single host, it is not comprehensive nor robust enough to be considered
# a proper enterprise installer on its own. Production installations will
# typically require significant adaptations or an entirely different
# method of installation. Please adapt it to your needs.

# SPECIFYING PARAMETERS
#
# If you supply no parameters, all components are installed on one host
# with default configuration, which should give you a running demo,
# given a usable install method.
#
# For a kickstart, you can supply further kernel parameters (in addition
# to the ks=location itself).
# e.g. virt-install ... -x "ks=http://.../openshift.ks domain=example.com"
#
# As a bash script, just add the parameters as bash variables at the top
# of the script (or export environment variables). Kickstart parameters
# are mapped to uppercase bash variables prepended with CONF_ so for
# example, "domain=example.com" as a kickstart parameter would be
# "CONF_DOMAIN=example.com" for the script.
#
# Available parameters are listed at length below the following notes.

# IMPORTANT NOTES - DEPENDENCIES
#
# Configuring sources for yum to install packages can be the hardest part
# of an installation. This script enables several methods to automatically
# configure the necessary repositories, which are described in parameters
# below. If you already configured repositories prior to running this
# script, you may leave the default method (which is to do nothing);
# otherwise you will need to modify the script or provide parameters to
# configure install sources.
#
# In order for the %post section to succeed, yum must have access to the
# latest RHEL 6 packages. The %post section does not share the method
# used in the base install (network, DVD, etc.). Either by modifying
# the base install, the %post script, or the script parameters, you must
# ensure that subscriptions or plain yum repos are available for RHEL.
#
# Similarly, the main OpenShift dependencies require OpenShift repos, and
# JBoss cartridges require packages from JBoss repos, so you must ensure
# these are configured for the %post script to run. Due to the complexity
# involved in this configuration, we recommend specifying parameters to
# use one of the script's install methods.
#
# DO NOT install with third-party (non-RHEL) repos enabled (e.g. EPEL).
# You may install different package versions than OpenShift expects and
# be in for a long troubleshooting session. Also avoid pre-installing
# third-party software like Puppet for the same reason.

# OTHER IMPORTANT NOTES
#
# If used as a kickstart, you will almost certainly want to change the
# root password or authorized keys (or both) specified in the kickstart,
# and/or set up another user/group with sudo access so that you can
# access the system after installation.
#
# If you install a broker, the rhc client is installed as well, for
# convenient local testing. Also, a test OpenShift user "demo" with
# password "changeme" is created for use by the default local file
# authentication option.
#
# If you want to use the broker from a client outside the installation,
# then of course that client must be using a DNS server that knows
# about (or is) the DNS server for the installation. Otherwise you will
# have DNS failures when creating the app and be unable to reach it in a
# browser.
#

# MANUAL TASKS
#
# This script attempts to automate as many tasks as it reasonably can.
# Unfortunately, it is constrained to setting up only a single host at a
# time. In a multi-host setup, you will need to do the following after
# the script has completed.
#
# 1. Set up DNS entries for hosts
#    If you installed BIND with the script, then any other components
#    the script installed on the same host received DNS entries.
#    Other hosts must all be defined manually, including at least your
#    node hosts. oo-register-dns may be useful for this.
#
# 2. Copy public rsync key to enable moving gears
#    The broker rsync public key needs to go on nodes, but there is no
#    good way to script that generically. Nodes should not have
#    password-less access to brokers to copy the .pub key, so this must
#    be performed manually on each node host:
#       # scp root@broker:/etc/openshift/rsync_id_rsa.pub /root/.ssh/
#    (above step will ask for the root password of the broker machine)
#       # cat /root/.ssh/rsync_id_rsa.pub >> /root/.ssh/authorized_keys
#       # rm /root/.ssh/rsync_id_rsa.pub
#    If you skip this, each gear move will require typing root passwords
#    for each of the node hosts involved.
#
# 3. Copy ssh host keys between the node hosts
#    All node hosts should identify as the same host, so that when gears
#    are moved between hosts, ssh and git don't give developers spurious
#    warnings about the host keys changing. So, copy /etc/ssh/ssh_* from
#    one node host to all the rest (or, if using the same image for all
#    hosts, just keep the keys from the image).


# PARAMETER DESCRIPTIONS

# actions / CONF_ACTIONS
#   Default: do_all_actions
#     Helpful steps: init_message,validate_preflight,configure_repos,
#                    install_rpms,configure_host,configure_openshift,
#                    reboot_after
#   Comma-separated list of bash functions to run.  This
#   setting is intended to allow configuration steps defined within this
#   file to be rerun selectively when the shell-script version of this
#   file is used.  For a normal installation, this setting can be left
#   at its default value.

# install_components / CONF_INSTALL_COMPONENTS
#   Comma-separated selections from the following:
#     broker - installs the broker webapp and tools
#     named - installs a BIND DNS server
#     activemq - installs the messaging bus
#     datastore - installs the MongoDB datastore
#     node - installs node functionality
#   Default: all.
#   Only the specified components are installed and configured.
#   e.g. install_components=broker,datastore only installs the broker
#   and DB, and assumes you have use other hosts for messaging and DNS.
#
# Example kickstart parameter:
#  install_components="node,broker,named,activemq,datastore"
# Example script variable:
#  CONF_INSTALL_COMPONENTS="node,broker,named,activemq,datastore"
#CONF_INSTALL_COMPONENTS="node"

# install_method / CONF_INSTALL_METHOD
#   Choose from the following ways to provide packages:
#     none - install sources are already set up when the script executes (DEFAULT)
#     yum - set up yum repos based on config
#       repos_base / CONF_REPOS_BASE -- see below
#       rhel_repo / CONF_RHEL_REPO -- see below
#       jboss_repo_base / CONF_JBOSS_REPO_BASE -- see below
#       rhel_optional_repo / CONF_RHEL_OPTIONAL_REPO -- see below
#     rhsm - use subscription-manager
#       sm_reg_name / CONF_SM_REG_NAME
#       sm_reg_pass / CONF_SM_REG_PASS
#       sm_reg_pool / CONF_SM_REG_POOL - pool ID for OpenShift subscription (required)
#       sm_reg_pool_rhel / CONF_SM_REG_POOL_RHEL - pool ID for RHEL subscription (optional)
#     rhn - use rhn-register
#       rhn_reg_name / CONF_RHN_REG_NAME
#       rhn_reg_pass / CONF_RHN_REG_PASS
#       rhn_reg_actkey / CONF_RHN_REG_ACTKEY - optional activation key
#   Default: none
#CONF_INSTALL_METHOD="yum"

# Hint: when running as a cmdline script, to enter your password invisibly:
#  read -s CONF_SM_REG_PASS
#  export CONF_SM_REG_PASS

# repos_base / CONF_REPOS_BASE
#   Default: https://mirror.openshift.com/pub/origin-server/nightly/enterprise/<latest>
#   The base URL for the OpenShift repositories used for the "yum"
#   install method - the part before Infrastructure/Node/etc.
#   Note that if this is the same as CONF_RHEL_REPO (without "/os"), then the
#   CDN format will be used instead, e.g. x86_64/ose-node/1.2/os
#CONF_REPOS_BASE="https://mirror.openshift.com/pub/origin-server/nightly/enterprise/<latest>"

# rhel_repo / CONF_RHEL_REPO
#   The URL for a RHEL 6 yum repository used with the "yum" install method.
#   Should end in /6Server/x86_64/os/

# rhel_optional_repo / CONF_RHEL_OPTIONAL_REPO
#   The URL for a RHEL 6 Optional yum repository used with the "yum" install method.
#   (only used if CONF_OPTIONAL_REPO is true below)
#   Should end in /6Server/x86_64/optional/os/

# jboss_repo_base / CONF_JBOSS_REPO_BASE
#   The base URL for the JBoss repositories used with the "yum"
#   install method - the part before jbeap/jbews - ends in /6/6Server/x86_64

# optional_repo / CONF_OPTIONAL_REPO
#   Enable unsupported RHEL "optional" repo.
#   Default: no
#CONF_OPTIONAL_REPO=1

# domain / CONF_DOMAIN
#   Default: example.com
#   The network domain under which apps and hosts will be placed.
#CONF_DOMAIN="example.com"

# broker_hostname / CONF_BROKER_HOSTNAME
# node_hostname / CONF_NODE_HOSTNAME
# named_hostname / CONF_NAMED_HOSTNAME
# activemq_hostname / CONF_ACTIVEMQ_HOSTNAME
# datastore_hostname / CONF_DATASTORE_HOSTNAME
#   Default: the root plus the domain, e.g. broker.example.com - except
#   named=ns1.example.com
#   These supply the FQDN of the hosts containing these components. Used
#   for configuring the host's name at install, and also for configuring
#   the broker application to reach the services needed.
#
#   IMPORTANT NOTE: if installing a nameserver, the script will create
#   DNS entries for the hostnames of the other components being
#   installed on this host as well. If you are using a nameserver set
#   up separately, you are responsible for all necessary DNS entries.
#CONF_BROKER_HOSTNAME="broker.example.com"
#CONF_NODE_HOSTNAME="node.example.com"
#CONF_NAMED_HOSTNAME="ns1.example.com"
#CONF_ACTIVEMQ_HOSTNAME="activemq.example.com"
#CONF_DATASTORE_HOSTNAME="mongodb.example.com"


# named_ip_addr / CONF_NAMED_IP_ADDR
#   Default: current IP if installing named, otherwise broker_ip_addr
#   This is used by every host to configure its primary nameserver.
#CONF_NAMED_IP_ADDR=10.10.10.10

# bind_key / CONF_BIND_KEY
#   When the nameserver is remote, use this to specify the HMAC-MD5 key
#   for updates. This is the "Key:" field from the .private key file
#   generated by dnssec-keygen.
#CONF_BIND_KEY=""

# bind_krb_keytab / CONF_BIND_KRB_KEYTAB
#   When the nameserver is remote, Kerberos keytab together with principal
#   can be used instead of the HMAC-MD5 key for updates.
#CONF_BIND_KRB_KEYTAB=""

# bind_krb_principal / CONF_BIND_KRB_PRINCIPAL
#   When the nameserver is remote, this Kerberos principal together with
#   Kerberos keytab can be used instead of the HMAC-MD5 key for updates.
#CONF_BIND_KRB_PRINCIPAL=""

# broker_ip_addr / CONF_BROKER_IP_ADDR
#   Default: the current IP (at install)
#   This is used for the node to record its broker. Also is the default
#   for the nameserver IP if none is given.
#CONF_BROKER_IP_ADDR=10.10.10.10

# node_ip_addr / CONF_NODE_IP_ADDR
#   Default: the current IP (at install)
#   This is used for the node to give a public IP, if different from the
#   one on its NIC.
#CONF_NODE_IP_ADDR=10.10.10.10

# A given node can only accept either V1 or V2 cartridges.
#CONF_NODE_V1_ENABLE=false

# no_ntp / CONF_NO_NTP
#   Default: false
#   Enabling this option prevents the installation script from
#   configuring NTP.  It is important that the time be synchronized
#   across hosts because MCollective messages have a TTL of 60 seconds
#   and may be dropped if the clocks are too far out of synch.  However,
#   NTP is not necessary if the clock will be kept in synch by some
#   other means.
#CONF_NO_NTP=true

# Passwords used to secure various services. You are advised to specify
# only alphanumeric values in this script as others may cause syntax
# errors depending on context. If non-alphanumeric values are required,
# update them separately after installation.
#
# activemq_admin_password / CONF_ACTIVEMQ_ADMIN_PASSWORD
#   Default: randomized
#   This is the admin password for the ActiveMQ admin console, which is
#   not needed by OpenShift but might be useful in troubleshooting.
#CONF_ACTIVEMQ_ADMIN_PASSWORD="ChangeMe"


# mcollective_user / CONF_MCOLLECTIVE_USER
# mcollective_password / CONF_MCOLLECTIVE_PASSWORD
#   Default: mcollective/marionette
#   This is the user and password shared between broker and node for
#   communicating over the mcollective topic channels in ActiveMQ. Must
#   be the same on all broker and node hosts.
#CONF_MCOLLECTIVE_USER="mcollective"
#CONF_MCOLLECTIVE_PASSWORD="mcollective"

# mongodb_admin_user / CONF_MONGODB_ADMIN_USER
# mongodb_admin_password / CONF_MONGODB_ADMIN_PASSWORD
#   Default: admin:mongopass
#   These are the username and password of the administrative user that
#   will be created in the MongoDB datastore. These credentials are not
#   used by in this script or by OpenShift, but an administrative user
#   must be added to MongoDB in order for it to enforce authentication.
#   Note: The administrative user will not be created if
#   CONF_NO_DATASTORE_AUTH_FOR_LOCALHOST is enabled.
#CONF_MONGODB_ADMIN_USER="admin"
#CONF_MONGODB_ADMIN_PASSWORD="mongopass"

# mongodb_broker_user / CONF_MONGODB_BROKER_USER
# mongodb_broker_password / CONF_MONGODB_BROKER_PASSWORD
#   Default: openshift:mongopass
#   These are the username and password of the normal user that will be
#   created for the broker to connect to the MongoDB datastore. The
#   broker application's MongoDB plugin is also configured with these
#   values.
#CONF_MONGODB_BROKER_USER="openshift"
#CONF_MONGODB_BROKER_PASSWORD="mongopass"

# mongodb_name / CONF_MONGODB_NAME
#   Default: openshift_broker
#   This is the name of the database in MongoDB in which the broker will
#   store data.
#CONF_MONGODB_NAME="openshift_broker"

# openshift_user1 / CONF_OPENSHIFT_USER1
# openshift_password1 / CONF_OPENSHIFT_PASSWORD1
#   Default: demo/changeme
#   This user and password are entered in the /etc/openshift/htpasswd
#   file as a demo/test user. You will likely want to remove it after
#   installation (or just use a different auth method).
#CONF_OPENSHIFT_USER1="demo"
#CONF_OPENSHIFT_PASSWORD1="changeme"

# conf_broker_auth_salt / CONF_BROKER_AUTH_SALT
#CONF_BROKER_AUTH_SALT=""

# conf_broker_session_secret / CONF_BROKER_SESSION_SECRET
#CONF_BROKER_SESSION_SECRET=""

# conf_console_session_secret / CONF_CONSOLE_SESSION_SECRET
#CONF_CONSOLE_SESSION_SECRET=""

#conf_valid_gear_sizes / CONF_VALID_GEAR_SIZES   (comma-separated list)
#CONF_VALID_GEAR_SIZES="small"

# The KrbServiceName value for mod_auth_kerb configuration
#CONF_BROKER_KRB_SERVICE_NAME=""

# The KrbAuthRealms value for mod_auth_kerb configuration
#CONF_BROKER_KRB_AUTH_REALMS=""

# The Krb5KeyTab value of mod_auth_kerb is not configurable -- the keytab
# is expected in /var/www/openshift/broker/httpd/conf.d/http.keytab

#Begin Kickstart Script
install
text
skipx

# NB: Be sure to change the password before running this script.
rootpw  --iscrypted $6$QgevUVWY7.dTjKz6$jugejKU4YTngbFpfNlqrPsiE4sLJSj/ahcfqK8fE5lO0jxDhvdg59Qjk9Qn3vNPAUTWXOp9mchQDy6EV9.XBW1

lang en_US.UTF-8
keyboard us
timezone --utc America/New_York

services --enabled=ypbind,ntpd,network,logwatch
network --onboot yes --device eth0
firewall --service=ssh
authconfig --enableshadow --passalgo=sha512
selinux --enforcing

bootloader --location=mbr --driveorder=vda --append=" rhgb crashkernel=auto quiet console=ttyS0"

clearpart --all --initlabel
firstboot --disable
reboot

part /boot --fstype=ext4 --size=500
part pv.253002 --grow --size=1
volgroup vg_vm1 --pesize=4096 pv.253002
logvol / --fstype=ext4 --name=lv_root --vgname=vg_vm1 --grow --size=1024 --maxsize=51200
logvol swap --name=lv_swap --vgname=vg_vm1 --grow --size=2016 --maxsize=4032

%packages
@core
@server-policy
ntp
git

%post --log=/root/anaconda-post.log

# During a kickstart you can tail the log file showing %post execution
# by using the following command:
#    tailf /mnt/sysimage/root/anaconda-post.log

# You can use sed to extract just the %post section:
#    sed -e '0,/^%post/d;/^%end/,$d'
# Be sure to reboot after installation if using the %post this way.

# Log the command invocations (and not merely output) in order to make
# the log more useful.
set -x


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


configure_repos()
{
  echo "OpenShift: Begin configuring repos."
  # Determine which channels we need and define corresponding predicate
  # functions.

  # Make need_${repo}_repo return false by default.
  for repo in optional infra node jbosseap_cartridge client_tools jbosseap jbossews
  do
      eval "need_${repo}_repo() { false; }"
  done

  if is_true "$CONF_OPTIONAL_REPO"
  then
    need_optional_repo() { :; }
  fi

  if activemq || broker || datastore || named
  then
    need_infra_repo() { :; }
  fi

  if broker
  then
    need_client_tools_repo() { :; }
  fi

  if node
  then
    need_node_repo() { :; }
    need_jbosseap_cartridge_repo() { :; }
    need_jbosseap_repo() { :; }
    need_jbossews_repo() { :; }
  fi

  # The configure_yum_repos, configure_rhn_channels, and
  # configure_rhsm_channels functions will use the need_${repo}_repo
  # predicate functions define above.
  case "$CONF_INSTALL_METHOD" in
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

  # Install yum-plugin-priorities
  yum clean all
  echo "Installing yum-plugin-priorities; if something goes wrong here, check your install source."
  yum_install_or_exit -y yum-plugin-priorities
  echo "OpenShift: Completed configuring repos."
}

configure_yum_repos()
{
  configure_rhel_repo

  if need_optional_repo
  then
    configure_optional_repo
  fi

  if need_infra_repo
  then
    configure_broker_repo
  fi

  if need_node_repo
  then
    configure_node_repo
  fi

  if need_jbosseap_cartridge_repo
  then
    configure_jbosseap_cartridge_repo
  fi

  if need_jbosseap_repo
  then
    configure_jbosseap_repo
  fi

  if need_jbossews_repo
  then
    configure_jbossews_repo
  fi

  if need_client_tools_repo
  then
    configure_client_tools_repo
  fi
}

configure_rhel_repo()
{
  # In order for the %post section to succeed, it must have a way of 
  # installing from RHEL. The post section cannot access the method that
  # was used in the base install. This configures a RHEL yum repo which
  # you must supply.
  cat > /etc/yum.repos.d/rhel.repo <<YUM
[rhel6]
name=RHEL 6 base OS
baseurl=${CONF_RHEL_REPO}
enabled=1
gpgcheck=0
priority=2
sslverify=false
exclude=tomcat6*

YUM
}

configure_optional_repo()
{
  cat > /etc/yum.repos.d/rheloptional.repo <<YUM
[rhel6_optional]
name=RHEL 6 Optional
baseurl=${CONF_RHEL_OPTIONAL_REPO}
enabled=1
gpgcheck=0
priority=2
sslverify=false

YUM
}

ose_yum_repo_url()
{
    channel=$1 #one of: Client,Infrastructure,Node,JBoss_EAP6_Cartridge
    if [ "${CONF_RHEL_REPO%/}" == "${repos_base%/}/os" ] # same repo base as RHEL?
    then # use the release CDN URLs
      declare -A map
      map=([Client]=ose-rhc [Infrastructure]=ose-infra [Node]=ose-node [JBoss_EAP6_Cartridge]=ose-jbosseap)
      echo "$repos_base/${map[$channel]}/1.2/os"
    else # use the nightly puddle URLs
      echo "$repos_base/$channel/x86_64/os/"
    fi
}

configure_client_tools_repo()
{
  # Enable repo with the puddle for broker packages.
  cat > /etc/yum.repos.d/openshift-client.repo <<YUM
[openshift_client]
name=OpenShift Client
baseurl=$(ose_yum_repo_url Client)
enabled=1
gpgcheck=0
priority=1
sslverify=false

YUM
}

configure_broker_repo()
{
  # Enable repo with the puddle for broker packages.
  cat > /etc/yum.repos.d/openshift-infrastructure.repo <<YUM
[openshift_infrastructure]
name=OpenShift Infrastructure
baseurl=$(ose_yum_repo_url Infrastructure)
enabled=1
gpgcheck=0
priority=1
sslverify=false

YUM
}

configure_node_repo()
{
  # Enable repo with the puddle for node packages.
  cat > /etc/yum.repos.d/openshift-node.repo <<YUM
[openshift_node]
name=OpenShift Node
baseurl=$(ose_yum_repo_url Node)
enabled=1
gpgcheck=0
priority=1
sslverify=false

YUM
}

configure_jbosseap_cartridge_repo()
{
  # Enable repo with the puddle for the JBossEAP cartridge package.
  cat > /etc/yum.repos.d/openshift-jboss.repo <<YUM
[openshift_jbosseap]
name=OpenShift JBossEAP
baseurl=$(ose_yum_repo_url JBoss_EAP6_Cartridge)
enabled=1
gpgcheck=0
priority=1
sslverify=false

YUM
}

configure_jbosseap_repo()
{
  # The JBossEAP cartridge depends on Red Hat's JBoss packages.

  if [ "x${CONF_JBOSS_REPO_BASE}" != "x" ]
  then
  ## configure JBossEAP repo
    cat <<YUM > /etc/yum.repos.d/jbosseap.repo
[jbosseap]
name=jbosseap
baseurl=${CONF_JBOSS_REPO_BASE}/jbeap/6/os
enabled=1
priority=3
gpgcheck=0

YUM

  fi
}

configure_jbossews_repo()
{
  # The JBossEWS cartridge depends on Red Hat's JBoss packages.
  if [ "x${CONF_JBOSS_REPO_BASE}" != "x" ]
  then
  ## configure JBossEWS repo
    cat <<YUM > /etc/yum.repos.d/jbossews.repo
[jbossews]
name=jbossews
baseurl=${CONF_JBOSS_REPO_BASE}/jbews/2/os
enabled=1
priority=3
gpgcheck=0

YUM

  fi
}

configure_rhn_channels()
{
  if [ "x$CONF_RHN_REG_ACTKEY" != x ]; then
    echo "Register with RHN using an activation key"
    rhnreg_ks --activationkey=${CONF_RHN_REG_ACTKEY} --profilename=${hostname} || abort_install
  else
    echo "Register with RHN with username and password"
    rhnreg_ks --profilename=${hostname} --username ${CONF_RHN_REG_NAME} --password ${CONF_RHN_REG_PASS} || abort_install
  fi

  # RHN method for setting yum priorities and excludes:
  RHNPLUGINCONF="/etc/yum/pluginconf.d/rhnplugin.conf"

  # OSE packages are first priority
  if need_client_tools_repo
  then
    rhn-channel --add --channel rhel-x86_64-server-6-ose-1.2-rhc --user ${CONF_RHN_REG_NAME} --password ${CONF_RHN_REG_PASS} || abort_install
    echo -e "[rhel-x86_64-server-6-ose-1.2-rhc]\npriority=1\n" >> $RHNPLUGINCONF
  fi

  if need_infra_repo
  then
    rhn-channel --add --channel rhel-x86_64-server-6-ose-1.2-infrastructure --user ${CONF_RHN_REG_NAME} --password ${CONF_RHN_REG_PASS} || abort_install
    echo -e "[rhel-x86_64-server-6-ose-1.2-infrastructure]\npriority=1\n" >> $RHNPLUGINCONF
  fi

  if need_node_repo
  then
    rhn-channel --add --channel rhel-x86_64-server-6-ose-1.2-node --user ${CONF_RHN_REG_NAME} --password ${CONF_RHN_REG_PASS} || abort_install
    echo -e "[rhel-x86_64-server-6-ose-1.2-node]\npriority=1\n" >> $RHNPLUGINCONF
  fi

  if need_jbosseap_repo
  then
    rhn-channel --add --channel rhel-x86_64-server-6-ose-1.2-jbosseap --user ${CONF_RHN_REG_NAME} --password ${CONF_RHN_REG_PASS} || abort_install
    echo -e "[rhel-x86_64-server-6-ose-1.2-jbosseap]\npriority=1\n" >> $RHNPLUGINCONF
  fi

  # RHEL packages are second priority
  echo -e "[rhel-x86_64-server-6]\npriority=2\nexclude=tomcat6*\n" >> $RHNPLUGINCONF

  # JBoss packages are third priority -- and all else is lower
  if need_jbosseap_repo
  then
    rhn-channel --add --channel jbappplatform-6-x86_64-server-6-rpm --user ${CONF_RHN_REG_NAME} --password ${CONF_RHN_REG_PASS} || abort_install
    echo -e "[jbappplatform-6-x86_64-server-6-rpm]\npriority=3\n" >> $RHNPLUGINCONF
  fi

  if need_jbossews_repo
  then
    rhn-channel --add --channel jb-ews-2-x86_64-server-6-rpm --user ${CONF_RHN_REG_NAME} --password ${CONF_RHN_REG_PASS} || abort_install
    echo -e "[jb-ews-2-x86_64-server-6-rpm]\npriority=3\n" >> $RHNPLUGINCONF
  fi

  if need_optional_repo
  then
    rhn-channel --add --channel rhel-x86_64-server-optional-6 --user ${CONF_RHN_REG_NAME} --password ${CONF_RHN_REG_PASS} || abort_install
  fi
}

configure_rhsm_channels()
{
   echo "Register with RHSM"
   subscription-manager register --username=$CONF_SM_REG_NAME --password=$CONF_SM_REG_PASS || abort_install
   # add the necessary subscriptions
   if [ "x$CONF_SM_REG_POOL_RHEL" == x ]; then
     echo "Registering RHEL with any available subscription"
     subscription-manager attach --auto || abort_install
   else
     echo "Registering RHEL subscription from pool id $CONF_SM_REG_POOL_RHEL"
     subscription-manager attach --pool $CONF_SM_REG_POOL_RHEL || abort_install
   fi
   echo "Registering OpenShift subscription from pool id $CONF_SM_REG_POOL_RHEL"
   subscription-manager attach --pool $CONF_SM_REG_POOL || abort_install

   # have yum sync new list of repos from rhsm before changing settings
   yum repolist

   # Note: yum-config-manager never indicates errors in return code, and the output is difficult to parse; so,
   # it is tricky to determine when these fail due to subscription problems etc.

   # configure the RHEL subscription
   yum-config-manager --setopt=rhel-6-server-rpms.priority=2 rhel-6-server-rpms --save
   yum-config-manager --setopt="rhel-6-server-rpms.exclude=tomcat6*" rhel-6-server-rpms --save
   if need_optional_repo
   then
     yum-config-manager --enable rhel-6-server-optional-rpms
   fi

   # and the OpenShift subscription
   if need_infra_repo
   then
     yum-config-manager --enable rhel-server-ose-1.2-infra-6-rpms
     yum-config-manager --setopt=rhel-server-ose-1.2-infra-6-rpms.priority=1 rhel-server-ose-1.2-infra-6-rpms --save
   fi

   if need_client_tools_repo
   then
     yum-config-manager --enable rhel-server-ose-1.2-rhc-6-rpms
     yum-config-manager --setopt=rhel-server-ose-1.2-rhc-6-rpms.priority=1 rhel-server-ose-1.2-rhc-6-rpms --save
   fi

   if need_node_repo
   then
     yum-config-manager --enable rhel-server-ose-1.2-node-6-rpms
     yum-config-manager --setopt=rhel-server-ose-1.2-node-6-rpms.priority=1 rhel-server-ose-1.2-node-6-rpms --save
   fi

   if need_jbosseap_cartridge_repo
   then
     yum-config-manager --enable rhel-server-ose-1.2-jbosseap-6-rpms
     yum-config-manager --setopt=rhel-server-ose-1.2-jbosseap-6-rpms.priority=1 rhel-server-ose-1.2-jbosseap-6-rpms --save
   fi

   # and JBoss subscriptions for the node
   if need_jbosseap_repo
   then
     yum-config-manager --enable jb-eap-6-for-rhel-6-server-rpms
     yum-config-manager --setopt=jb-eap-6-for-rhel-6-server-rpms.priority=3 jb-eap-6-for-rhel-6-server-rpms --save
     yum-config-manager --disable jb-eap-5-for-rhel-6-server-rpms
   fi

   if need_jbossews_repo
   then
     yum-config-manager --enable jb-ews-2-for-rhel-6-server-rpms
     yum-config-manager --setopt=jb-ews-2-for-rhel-6-server-rpms.priority=3 jb-ews-2-for-rhel-6-server-rpms
     yum-config-manager --disable jb-ews-1-for-rhel-6-server-rpms
   fi
}

abort_install()
{
  # don't change this; could be used as an automation cue.
  echo "Aborting OpenShift Installation."
  exit 1
}

yum_install_or_exit()
{
  yum install $*
  if [ $? -ne 0 ]
  then
    echo "Command failed: yum install $*"
    echo "Please ensure relevant repos/subscriptions are configured."
    abort_install
  fi
}

# Install the client tools.
install_rhc_pkg()
{
  yum_install_or_exit -y rhc
  # set up the system express.conf so this broker will be used by default
  echo -e "\nlibra_server = '${broker_hostname}'" >> /etc/openshift/express.conf
}

# Install broker-specific packages.
install_broker_pkgs()
{
  pkgs="openshift-origin-broker"
  pkgs="$pkgs openshift-origin-broker-util"
  pkgs="$pkgs rubygem-openshift-origin-msg-broker-mcollective"
  pkgs="$pkgs mcollective-client"
  pkgs="$pkgs rubygem-openshift-origin-auth-remote-user"
  pkgs="$pkgs rubygem-openshift-origin-dns-nsupdate"
  pkgs="$pkgs openshift-origin-console"


  yum_install_or_exit -y $pkgs
}

# Install node-specific packages.
install_node_pkgs()
{
  pkgs="rubygem-openshift-origin-node ruby193-rubygem-passenger-native"
  pkgs="$pkgs openshift-origin-port-proxy"
  pkgs="$pkgs openshift-origin-node-util"
  pkgs="$pkgs mcollective openshift-origin-msg-node-mcollective"

  # We use semanage in this script, so we need to install
  # policycoreutils-python.
  pkgs="$pkgs policycoreutils-python"

  yum_install_or_exit -y $pkgs
}

# Remove abrt-addon-python if necessary
# https://bugzilla.redhat.com/show_bug.cgi?id=907449
# This only affects the python v2 cart
remove_abrt_addon_python()
{
  if grep 'Enterprise Linux Server release 6.4' /etc/redhat-release && rpm -q abrt-addon-python && rpm -q openshift-origin-cartridge-python; then
    yum remove -y abrt-addon-python || abort_install
  fi
}

# Install any cartridges developers may want.
install_cartridges()
{
  # Following are cartridge rpms that one may want to install here:
  if is_true "$node_v1_enable"
  then
    # Embedded cron support. This is required on node hosts.
    carts="openshift-origin-cartridge-cron-1.4"

    # diy app.
    carts="$carts openshift-origin-cartridge-diy-0.1"

    # haproxy-1.4 support.
    carts="$carts openshift-origin-cartridge-haproxy-1.4"

    # JBossEWS1.0 support.
    # Note: Be sure to subscribe to the JBossEWS entitlements during the
    # base install or in configure_jbossews_repo.
    carts="$carts openshift-origin-cartridge-jbossews-1.0"

    # JBossEAP6.0 support.
    # Note: Be sure to subscribe to the JBossEAP entitlements during the
    # base install or in configure_jbosseap_repo.
    carts="$carts openshift-origin-cartridge-jbosseap-6.0"

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
  else
    # Embedded cron support. This is required on node hosts.
    carts="openshift-origin-cartridge-cron"

    # diy app.
    carts="$carts openshift-origin-cartridge-diy"

    # haproxy support.
    carts="$carts openshift-origin-cartridge-haproxy"

    # JBossEWS support.
    # Note: Be sure to subscribe to the JBossEWS entitlements during the
    # base install or in configure_jbossews_repo.
    carts="$carts openshift-origin-cartridge-jbossews"

    # JBossEAP support.
    # Note: Be sure to subscribe to the JBossEAP entitlements during the
    # base install or in configure_jbosseap_repo.
    carts="$carts openshift-origin-cartridge-jbosseap"

    # Jenkins server for continuous integration.
    carts="$carts openshift-origin-cartridge-jenkins"

    # Embedded jenkins client.
    carts="$carts openshift-origin-cartridge-jenkins-client"

    # Embedded MySQL.
    carts="$carts openshift-origin-cartridge-mysql"

    # mod_perl support.
    carts="$carts openshift-origin-cartridge-perl"

    # PHP support.
    carts="$carts openshift-origin-cartridge-php"

    # Embedded PostgreSQL.
    carts="$carts openshift-origin-cartridge-postgresql"

    # Python support.
    carts="$carts openshift-origin-cartridge-python"

    # Ruby Rack support running on Phusion Passenger
    carts="$carts openshift-origin-cartridge-ruby"
  fi

  # When dependencies are missing, e.g. JBoss subscriptions,
  # still install as much as possible.
  #carts="$carts --skip-broken"

  yum_install_or_exit -y $carts
}

# Fix up SELinux policy on the broker.
configure_selinux_policy_on_broker()
{
  # We combine these setsebool commands into a single semanage command
  # because separate commands take a long time to run.
  (
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

  restorecon -rv /var/run
  # This should cover everything in the SCL, including passenger
  restorecon -rv /opt
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


  restorecon -rv /var/run
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
      # We add two rules.  The first checks whether the user's shell is
      # /usr/bin/oo-trap-user, which indicates that this is a gear user,
      # and skips the second rule if it is not.
      echo -e "session\t\t[default=1 success=ignore]\tpam_succeed_if.so quiet shell = /usr/bin/oo-trap-user" >> "$t"

      # The second rule enables polyinstantiation so that the user gets
      # private /tmp and /dev/shm directories.
      echo -e "session\t\trequired\tpam_namespace.so no_unmount_on_close" >> "$t"
    fi
  done

  # Configure the pam_namespace module to polyinstantiate the /tmp and
  # /dev/shm directories.  Above, we only enable pam_namespace for
  # OpenShift users, but to be safe, blacklist the root and adm users
  # to be sure we don't polyinstantiate their directories.
  echo "/tmp        \$HOME/.tmp/      user:iscript=/usr/sbin/oo-namespace-init root,adm" > /etc/security/namespace.d/tmp.conf
  echo "/dev/shm  tmpfs  tmpfs:mntopts=size=5M:iscript=/usr/sbin/oo-namespace-init root,adm" > /etc/security/namespace.d/shm.conf
}

configure_cgroups_on_node()
{
  for f in "runuser" "runuser-l" "sshd" "system-auth-ac"
  do
    t="/etc/pam.d/$f"
    if ! grep -q "pam_cgroup" "$t"
    then
      echo -e "session\t\toptional\tpam_cgroup.so" >> "$t"
    fi
  done

  cp -vf /opt/rh/ruby193/root/usr/share/gems/doc/openshift-origin-node-*/cgconfig.conf /etc/cgconfig.conf
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
    sed -i -e "/^[^[:blank:]]\\+[[:blank:]]\\+${geardata_mnt////\/\\+[[:blank:]]}/{/usrquota/! s/[[:blank:]]\\+/,usrquota&/4;}" /etc/fstab

    # Remount to get quotas enabled immediately.
    mount -o remount "${geardata_mnt}"

    # Generate user quota info for the mount point.
    quotacheck -cmug "${geardata_mnt}"

    # fix up selinux perms
    restorecon "${geardata_mnt}"aquota.user

    # (re)enable quotas
    quotaon "${geardata_mnt}"
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
  sed -i -e "s/^#MaxSessions .*$/MaxSessions 40/" /etc/ssh/sshd_config
  sed -i -e "s/^#MaxStartups .*$/MaxStartups 40/" /etc/ssh/sshd_config
}

install_datastore_pkgs()
{
  yum_install_or_exit -y mongodb-server
}

configure_datastore()
{
  # Require authentication.
  sed -i -e "s/^#auth = .*$/auth = true/" /etc/mongodb.conf

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
    sed -i -e "s/^bind_ip = .*$/bind_ip = 0.0.0.0/" /etc/mongodb.conf
  fi

  # Configure mongod to start on boot.
  chkconfig mongod on

  # Start mongod so we can perform some administration now.
  service mongod start

  # The init script lies to us as of version 2.0.2-1.el6_3: The start 
  # and restart actions return before the daemon is ready to accept
  # connections (appears to take time to initialize the journal). Thus
  # we need the following to wait until the daemon is really ready.
  echo "Waiting for MongoDB to start ($(date +%H:%M:%S))..."
  while :
  do
    echo exit | mongo && break
    sleep 5
  done
  echo "MongoDB is ready! ($(date +%H:%M:%S))"

  if is_false "$CONF_NO_DATASTORE_AUTH_FOR_LOCALHOST"
  then
    # Add an administrative user and a user that the broker will use.
    mongo <<EOF
use admin
db.addUser("${mongodb_admin_user}", "${mongodb_admin_password}")

db.auth("${mongodb_admin_user}", "${mongodb_admin_password}")

use ${mongodb_name}
db.addUser("${mongodb_broker_user}", "${mongodb_broker_password}")
EOF
  else
    # Add a user that the broker will use.
    mongo <<EOF
use ${mongodb_name}
db.addUser("${mongodb_broker_user}", "${mongodb_broker_password}")
EOF
  fi
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
  # We use --nostart below because activating the configuration here 
  # will produce errors.  Anyway, we only need the configuration 
  # activated Anaconda reboots, so --nostart makes sense in any case.

  lokkit --nostart --service=ssh
  lokkit --nostart --service=https
  lokkit --nostart --service=http

  # Allow connections to openshift-node-web-proxy
  lokkit --nostart --port=8000:tcp
  lokkit --nostart --port=8443:tcp

  chkconfig httpd on
  chkconfig network on
  is_false "$CONF_NO_NTP" && chkconfig ntpd on
  chkconfig sshd on
  chkconfig oddjobd on
  chkconfig openshift-node-web-proxy on
}


# Enable services to start on boot for the broker and fix up some issues.
enable_services_on_broker()
{
  # We use --nostart below because activating the configuration here 
  # will produce errors.  Anyway, we only need the configuration 
  # activated after Anaconda reboots, so --nostart makes sense.

  lokkit --nostart --service=ssh
  lokkit --nostart --service=https
  lokkit --nostart --service=http

  chkconfig httpd on
  chkconfig network on
  is_false "$CONF_NO_NTP" && chkconfig ntpd on
  chkconfig sshd on

  # Remove VirtualHost from the default ssl.conf to prevent a warning
   sed -i '/VirtualHost/,/VirtualHost/ d' /etc/httpd/conf.d/ssl.conf

  # make sure mcollective client log is created with proper ownership.
  # if root owns it, the broker (apache user) can't log to it.
  touch /var/log/mcollective-client.log
  chown apache:root /var/log/mcollective-client.log
}

# Configure mcollective on the broker to use ActiveMQ.
configure_mcollective_for_activemq_on_broker()
{
  cat <<EOF > /etc/mcollective/client.cfg
topicprefix = /topic/
main_collective = mcollective
collectives = mcollective
libdir = /opt/rh/ruby193/root/usr/libexec/mcollective
logfile = /var/log/mcollective-client.log
loglevel = debug
direct_addressing = 1

# Plugins
securityprovider=psk
plugin.psk = asimplething

connector = activemq
plugin.activemq.pool.size = 1
plugin.activemq.pool.1.host = ${activemq_hostname}
plugin.activemq.pool.1.port = 61613
plugin.activemq.pool.1.user = ${mcollective_user}
plugin.activemq.pool.1.password = ${mcollective_password}

# Facts
factsource = yaml
plugin.yaml = /etc/mcollective/facts.yaml

EOF
}


# Configure mcollective on the node to use ActiveMQ.
configure_mcollective_for_activemq_on_node()
{
  cat <<EOF > /etc/mcollective/server.cfg
topicprefix = /topic/
main_collective = mcollective
collectives = mcollective
libdir = /opt/rh/ruby193/root/usr/libexec/mcollective
logfile = /var/log/mcollective.log
loglevel = debug

daemonize = 1
direct_addressing = 1

# Plugins
securityprovider = psk
plugin.psk = asimplething

connector = activemq
plugin.activemq.pool.size = 1
plugin.activemq.pool.1.host = ${activemq_hostname}
plugin.activemq.pool.1.port = 61613
plugin.activemq.pool.1.user = ${mcollective_user}
plugin.activemq.pool.1.password = ${mcollective_password}

# Facts
factsource = yaml
plugin.yaml = /etc/mcollective/facts.yaml
EOF

  chkconfig mcollective on
}


install_activemq_pkgs()
{
  yum_install_or_exit -y activemq
}

configure_activemq()
{
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

  # only add the host property if it's not already there
  # (so you can run the script multiple times)
  grep '<property name="host" value="127.0.0.1" />' /etc/activemq/jetty.xml > /dev/null
  if [ $? -ne 0 ]; then
    sed -i -e '/name="port"/a<property name="host" value="127.0.0.1" />' /etc/activemq/jetty.xml
  fi

  sed -i -e "/admin:/s/admin,/${activemq_admin_password},/" /etc/activemq/jetty-realm.properties


  # Allow connections to ActiveMQ.
  lokkit --nostart --port=61613:tcp

  # Configure ActiveMQ to start on boot.
  chkconfig activemq on
}

install_named_pkgs()
{
  yum_install_or_exit -y bind bind-utils
}

configure_named()
{

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

  # Ensure we have a key for service named status to communicate with BIND.
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

  chgrp named -R /var/named
  chown named -R /var/named/dynamic
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

  # Configure the console with the correct domain
  sed -i -e "s/^DOMAIN_SUFFIX=.*$/DOMAIN_SUFFIX=${domain}/" \
      /etc/openshift/console.conf

  # Configure the broker with the correct hostname, and use random salt
  # to the data store (the host running MongoDB).
  sed -i -e "s/^CLOUD_DOMAIN=.*$/CLOUD_DOMAIN=${domain}/" \
      /etc/openshift/broker.conf
  echo AUTH_SALT=${broker_auth_salt} >> /etc/openshift/broker.conf

  # Configure the valid gear sizes for the broker
  sed -i -e "s/^VALID_GEAR_SIZES=.*/VALID_GEAR_SIZES=\"${conf_valid_gear_sizes}\"/" \
      /etc/openshift/broker.conf

  # Configure the session secret for the broker
  sed -i -e "s/# SESSION_SECRET=.*$/SESSION_SECRET=${broker_session_secret}/" \
      /etc/openshift/broker.conf

  # Configure the session secret for the console
  if [ `grep -c SESSION_SECRET /etc/openshift/console.conf` -eq 0 ]
  then
    echo "SESSION_SECRET=${console_session_secret}" >> /etc/openshift/console.conf
  fi

  if ! datastore
  then
    #mongo not installed locally, so point to given hostname
    sed -i -e "s/^MONGO_HOST_PORT=.*$/MONGO_HOST_PORT=\"${datastore_hostname}:27017\"/" /etc/openshift/broker.conf
  fi

  # configure MongoDB access
  sed -i -e "s/MONGO_PASSWORD=.*$/MONGO_PASSWORD=\"${mongodb_broker_password}\"/
            s/MONGO_USER=.*$/MONGO_USER=\"${mongodb_broker_user}\"/
            s/MONGO_DB=.*$/MONGO_DB=\"${mongodb_name}\"/" \
      /etc/openshift/broker.conf

  # Set the ServerName for httpd
  sed -i -e "s/ServerName .*$/ServerName ${hostname}/" \
      /etc/httpd/conf.d/000002_openshift_origin_broker_servername.conf

  # Configure the broker service to start on boot.
  chkconfig openshift-broker on
  chkconfig openshift-console on
}

# Configure the broker to use the remote-user authentication plugin.
configure_remote_user_auth_plugin()
{
  cp /etc/openshift/plugins.d/openshift-origin-auth-remote-user.conf{.example,}
}

configure_messaging_plugin()
{
  cp /etc/openshift/plugins.d/openshift-origin-msg-broker-mcollective.conf{.example,}
}

# Configure the broker to use the BIND DNS plug-in.
configure_dns_plugin()
{
  if [ "x$bind_key" = x ] && [ "x$bind_krb_keytab" = x ]
  then
    echo 'WARNING: Neither key nor keytab has been set for communication'
    echo 'with BIND. You will need to modify the value of BIND_KEYVALUE in'
    echo '/etc/openshift/plugins.d/openshift-origin-dns-nsupdate.conf'
    echo 'after installation.'
  fi

  mkdir -p /etc/openshift/plugins.d
  cat <<EOF > /etc/openshift/plugins.d/openshift-origin-dns-nsupdate.conf
BIND_SERVER="${named_ip_addr}"
BIND_PORT=53
BIND_ZONE="${domain}"
EOF
  if [ "x$bind_krb_keytab" = x ]
  then
    cat <<EOF >> /etc/openshift/plugins.d/openshift-origin-dns-nsupdate.conf
BIND_KEYNAME="${domain}"
BIND_KEYVALUE="${bind_key}"
EOF
  else
    cat <<EOF >> /etc/openshift/plugins.d/openshift-origin-dns-nsupdate.conf
BIND_KRB_PRINCIPAL="${bind_krb_principal}"
BIND_KRB_KEYTAB="${bind_krb_keytab}"
EOF
  fi
}

# Configure httpd for authentication.
configure_httpd_auth()
{
  # Configure mod_auth_kerb if both CONF_BROKER_KRB_SERVICE_NAME
  # and CONF_BROKER_KRB_AUTH_REALMS are specified
  if [ -n "$CONF_BROKER_KRB_SERVICE_NAME" ] && [ -n "$CONF_BROKER_KRB_AUTH_REALMS" ]
  then
    yum_install_or_exit -y mod_auth_kerb
    for d in /var/www/openshift/broker/httpd/conf.d /var/www/openshift/console/httpd/conf.d
    do
      sed -e "s#KrbServiceName.*#KrbServiceName ${CONF_BROKER_KRB_SERVICE_NAME}#" \
        -e "s#KrbAuthRealms.*#KrbAuthRealms ${CONF_BROKER_KRB_AUTH_REALMS}#" \
	$d/openshift-origin-auth-remote-user-kerberos.conf.sample > $d/openshift-origin-auth-remote-user-kerberos.conf
    done
    return
  fi

  # Install the Apache Basic Authentication configuration file.
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

# if the broker and node are on the same machine we need to manually update the
# nodes.db
fix_broker_routing()
{
  cat <<EOF >> /var/lib/openshift/.httpd.d/nodes.txt
__default__ REDIRECT:/console
__default__/console TOHTTPS:127.0.0.1:8118/console
__default__/broker TOHTTPS:127.0.0.1:8080/broker
EOF

  httxt2dbm -f DB -i /etc/httpd/conf.d/openshift/nodes.txt -o /etc/httpd/conf.d/openshift/nodes.db
  chown root:apache /etc/httpd/conf.d/openshift/nodes.txt /etc/httpd/conf.d/openshift/nodes.db
  chmod 750 /etc/httpd/conf.d/openshift/nodes.txt /etc/httpd/conf.d/openshift/nodes.db
}

configure_access_keys_on_broker()
{
  # Generate a broker access key for remote apps (Jenkins) to access
  # the broker.
  openssl genrsa -out /etc/openshift/server_priv.pem 2048
  openssl rsa -in /etc/openshift/server_priv.pem -pubout > /etc/openshift/server_pub.pem
  chown apache:apache /etc/openshift/server_pub.pem
  chmod 640 /etc/openshift/server_pub.pem

  # If a key pair already exists, delete it so that the ssh-keygen
  # command will not have to ask the user what to do.
  rm -f /root/.ssh/rsync_id_rsa /root/.ssh/rsync_id_rsa.pub

  # Generate a key pair for moving gears between nodes from the broker
  ssh-keygen -t rsa -b 2048 -P "" -f /root/.ssh/rsync_id_rsa
  cp /root/.ssh/rsync_id_rsa* /etc/openshift/
  # the .pub key needs to go on nodes, but there is no good way
  # to script that generically. Nodes should not have password-less
  # access to brokers to copy the .pub key, but this can be performed
  # manually:
  #   # scp root@broker:/etc/openshift/rsync_id_rsa.pub /root/.ssh/
  # the above step will ask for the root password of the broker machine
  #   # cat /root/.ssh/rsync_id_rsa.pub >> /root/.ssh/authorized_keys
  #   # rm /root/.ssh/rsync_id_rsa.pub
}

configure_wildcard_ssl_cert_on_node()
{
  # Generate a 2048 bit key and self-signed cert
  cat << EOF | openssl req -new -rand /dev/urandom \
	-newkey rsa:2048 -nodes -keyout /etc/pki/tls/private/localhost.key \
	-x509 -days 3650 \
	-out /etc/pki/tls/certs/localhost.crt 2> /dev/null
XX
SomeState
SomeCity
SomeOrganization
SomeOrganizationalUnit
*.${domain}
root@${domain}
EOF

}

configure_broker_ssl_cert()
{
  # Generate a 2048 bit key and self-signed cert
  cat << EOF | openssl req -new -rand /dev/urandom \
	-newkey rsa:2048 -nodes -keyout /etc/pki/tls/private/localhost.key \
	-x509 -days 3650 \
	-out /etc/pki/tls/certs/localhost.crt 2> /dev/null
XX
SomeState
SomeCity
SomeOrganization
SomeOrganizationalUnit
${broker_hostname}
root@${domain}
EOF
}

# Configure IP address and hostname.
configure_network()
{
  # Append some stuff to the DHCP configuration.
  cat <<EOF >> /etc/dhcp/dhclient-eth0.conf

prepend domain-name-servers ${named_ip_addr};
supersede host-name "${hostname%.${domain}}";
supersede domain-name "${domain}";
prepend domain-search "${domain}";
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
             s/^BROKER_HOST=.*$/BROKER_HOST=${broker_hostname}/" \
      /etc/openshift/node.conf

  echo $broker_hostname > /etc/openshift/env/OPENSHIFT_BROKER_HOST
  echo $domain > /etc/openshift/env/OPENSHIFT_CLOUD_DOMAIN

  if is_true "$node_v1_enable"
  then
    mkdir -p /var/lib/openshift/.settings
    touch /var/lib/openshift/.settings/v1_cartridge_format
  fi

  # Set the ServerName for httpd
  sed -i -e "s/ServerName .*$/ServerName ${hostname}/" \
      /etc/httpd/conf.d/000001_openshift_origin_node_servername.conf
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

# Given a list of arguments, define variables with the parameters
# specified on it so that from, e.g., "foo=bar baz" we get CONF_FOO=bar
# and CONF_BAZ=true in the environment.
parse_args()
{
  for word in "$@"
  do
    key="${word%%\=*}"
    case "$word" in
      (*=*) val="${word#*\=}" ;;
      (*) val=true ;;
    esac
    eval "CONF_${key^^}"'="$val"'
  done
}

# Parse the kernel command-line using parse_args.
parse_kernel_cmdline()
{
  parse_args $(cat /proc/cmdline)
}

# Parse command-line arguments using parse_args.
parse_cmdline()
{
  parse_args "$@"
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
# running this script, based on the output of the `ip addr show` command
#
# In addition, the $nameservers variable will be set to
# a semicolon-delimited list of nameservers, suitable for use in
# named.conf, based on the existing contents of /etc/resolv.conf, and
# either $bind_krb_keytab and $bind_krb_principal will be set to the
# value of CONF_BIND_KRB_KEYTAB and CONF_BIND_KRB_PRINCIPAL, or the
# the $bind_key variable will be set to the value of CONF_BIND_KEY.
#
# The following variables will be defined:
#
#   actions
#   activemq_hostname
#   bind_key		# if bind_krb_keytab and bind_krb_principal unset
#   bind_krb_keytab
#   bind_krb_principal
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
# This function makes use of variables that may be set by parse_kernel_cmdline
# based on the content of /proc/cmdline or may be hardcoded by modifying
# this file.  All of these variables are optional; best attempts are
# made at determining reasonable defaults.
#
# The following variables are used:
#
#   CONF_ACTIONS
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
#   CONF_NODE_V1_ENABLE
#   CONF_REPOS_BASE
set_defaults()
{
  # By default, we run do_all_actions, which performs all the steps of
  # a normal installation.
  actions="${CONF_ACTIONS:-do_all_actions}"

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
  repos_base="${CONF_REPOS_BASE:-${repos_base_default}}"

  # There a no defaults for these. Customers should be using 
  # subscriptions via RHN. Internally we use private systems.
  rhel_repo="$CONF_RHEL_REPO"
  jboss_repo_base="$CONF_JBOSS_REPO_BASE"
  rhel_optional_repo="$CONF_RHEL_OPTIONAL_REPO"

  # The domain name for the OpenShift Enterprise installation.
  domain="${CONF_DOMAIN:-example.com}"

  # hostnames to use for the components (could all resolve to same host)
  broker_hostname="${CONF_BROKER_HOSTNAME:-broker.${domain}}"
  node_hostname="${CONF_NODE_HOSTNAME:-node.${domain}}"
  named_hostname="${CONF_NAMED_HOSTNAME:-ns1.${domain}}"
  activemq_hostname="${CONF_ACTIVEMQ_HOSTNAME:-activemq.${domain}}"
  datastore_hostname="${CONF_DATASTORE_HOSTNAME:-datastore.${domain}}"

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
  fi

  # Grab the IP address set during installation.
  cur_ip_addr="$(/sbin/ip addr show | awk '/inet .*global/ { split($2,a,"/"); print a[1]; }' | head -1)"

  # Unless otherwise specified, the broker is assumed to be the current
  # host.
  broker_ip_addr="${CONF_BROKER_IP_ADDR:-$cur_ip_addr}"

  # Unless otherwise specified, the node is assumed to be the current
  # host.
  node_ip_addr="${CONF_NODE_IP_ADDR:-$cur_ip_addr}"

  node_v1_enable="${CONF_NODE_V1_ENABLE:-false}"

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

  # Set $bind_krb_keytab and $bind_krb_principal to the values of
  # $CONF_BIND_KRB_KEYTAB and $CONF_BIND_KRB_PRINCIPAL if these values
  # are both non-empty, or set $bind_key to the value of $CONF_BIND_KEY
  # if the latter is non-empty.
  if [ "x$CONF_BIND_KRB_KEYTAB" != x ] && [ "x$CONF_BIND_KRB_PRINCIPAL" != x ] ; then
  bind_krb_keytab="$CONF_BIND_KRB_KEYTAB"
  bind_krb_principal="$CONF_BIND_KRB_PRINCIPAL"
  else
  bind_key="$CONF_BIND_KEY"
  fi

  # Set $conf_valid_gear_sizes to $CONF_VALID_GEAR_SIZES
  broker && conf_valid_gear_sizes="${CONF_VALID_GEAR_SIZES:-small}"

  # Generate a random salt for the broker authentication.
  randomized=$(openssl rand -base64 20)
  broker && broker_auth_salt="${CONF_BROKER_AUTH_SALT:-${randomized}}"

  # Generate a random session secret for broker sessions.
  randomized=$(openssl rand -hex 64)
  broker && broker_session_secret="${CONF_BROKER_SESSION_SECRET:-${randomized}}"

  # Generate a random session secret for console sessions.
  broker && console_session_secret="${CONF_CONSOLE_SESSION_SECRET:-${randomized}}"

  # Set default passwords
  #
  #   This is the admin password for the ActiveMQ admin console, which 
  #   is not needed by OpenShift but might be useful in troubleshooting.
  activemq && activemq_admin_password="${CONF_ACTIVEMQ_ADMIN_PASSWORD:-${randomized//[![:alnum:]]}}"

  #   This is the user and password shared between broker and node for
  #   communicating over the mcollective topic channels in ActiveMQ. 
  #   Must be the same on all broker and node hosts.
  mcollective_user="${CONF_MCOLLECTIVE_USER:-mcollective}"
  mcollective_password="${CONF_MCOLLECTIVE_PASSWORD:-marionette}"

  #   These are the username and password of the administrative user 
  #   that will be created in the MongoDB datastore. These credentials
  #   are not used by in this script or by OpenShift, but an
  #   administrative user must be added to MongoDB in order for it to
  #   enforce authentication.
  mongodb_admin_user="${CONF_MONGODB_ADMIN_USER:-admin}"
  mongodb_admin_password="${CONF_MONGODB_ADMIN_PASSWORD:-${CONF_MONGODB_PASSWORD:-mongopass}}"

  #   These are the username and password of the normal user that will
  #   be created for the broker to connect to the MongoDB datastore. The
  #   broker application's MongoDB plugin is also configured with these
  #   values.
  mongodb_broker_user="${CONF_MONGODB_BROKER_USER:-openshift}"
  mongodb_broker_password="${CONF_MONGODB_BROKER_PASSWORD:-${CONF_MONGODB_PASSWORD:-mongopass}}"

  #   This is the name of the database in MongoDB in which the broker
  #   will store data.
  mongodb_name="${CONF_MONGODB_NAME:-openshift_broker}"

  #   This user and password are entered in the /etc/openshift/htpasswd
  #   file as a demo/test user. You will likely want to remove it after
  #   installation (or just use a different auth method).
  broker && openshift_user1="${CONF_OPENSHIFT_USER1:-demo}"
  broker && openshift_password1="${CONF_OPENSHIFT_PASSWORD1:-changeme}"
}


########################################################################
#
# These top-level steps also emit cues for automation to track progress.
# Please don't change output wording arbitrarily.

init_message()
{
  echo_installation_intentions
  configure_console_msg
}

validate_preflight()
{
  echo "OpenShift: Begin preflight validation."
  failure=
  # Test that this isn't RHEL < 6 or Fedora
  # Test that SELinux is at least present and not Disabled
  # Test that rpm/yum exists and isn't totally broken
  # Test that known problematic RPMs aren't present
  # Test that DNS resolution is sane
  # ... ?
  [ "$failure" ] && abort_install
  echo "OpenShift: Completed preflight validation."
}

install_rpms()
{
  echo "OpenShift: Begin installing RPMs."
  # we often rely on latest selinux policy and other updates
  yum update -y || abort_install
  # Install ntp and ntpdate because they may not be present in a RHEL
  # minimal install.
  yum_install_or_exit -y ntp ntpdate

  # install what we need for various components
  named && install_named_pkgs
  datastore && install_datastore_pkgs
  activemq && install_activemq_pkgs
  broker && install_broker_pkgs
  node && install_node_pkgs
  node && install_cartridges
  node && remove_abrt_addon_python
  broker && install_rhc_pkg
  echo "OpenShift: Completed installing RPMs."
}

configure_host()
{
  echo "OpenShift: Begin configuring host."
  is_false "$CONF_NO_NTP" && synchronize_clock
  # Note: configure_named must run before configure_controller if we are
  # installing both named and broker on the same host.
  named && configure_named
  update_resolv_conf
  configure_network
  configure_hostname
  echo "OpenShift: Completed configuring host."
}

configure_openshift()
{
  echo "OpenShift: Begin configuring OpenShift."

  # prepare services the broker and node depend on
  datastore && configure_datastore
  activemq && configure_activemq
  broker && configure_mcollective_for_activemq_on_broker
  node && configure_mcollective_for_activemq_on_node

  # configure broker and/or node
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
  broker && configure_messaging_plugin
  broker && configure_dns_plugin
  broker && configure_httpd_auth
  broker && configure_broker_ssl_cert

  node && configure_port_proxy
  node && configure_gears
  node && configure_node
  node && configure_wildcard_ssl_cert_on_node
  node && update_openshift_facts_on_node

  node && broker && fix_broker_routing

  echo "OpenShift: Completed configuring OpenShift."
}

reboot_after()
{
  echo "OpenShift: Rebooting after install."
  reboot
}

do_all_actions()
{
  init_message
  validate_preflight
  configure_repos
  install_rpms
  configure_host
  configure_openshift
  echo "Installation and configuration is complete;"
  echo "please reboot to start all services properly."
  echo "Then validate brokers/nodes with oo-diagnostics."
}

########################################################################

# parse_kernel_cmdline is only needed for kickstart and not if this %post
# section is extracted and executed on a running system.
parse_kernel_cmdline

# parse_cmdline is only needed for shell scripts generated by extracting
# this %post section.
#parse_cmdline "$@"

set_defaults

for action in ${actions//,/ }
do
  if ! [ "$(type -t "$action")" = function ]
  then
    echo "Invalid action: ${action}"
    abort_install
  fi
  "$action"
done

%end

