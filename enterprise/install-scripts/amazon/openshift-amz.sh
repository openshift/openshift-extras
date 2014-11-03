#!/bin/sh

CONF_PREFIX="${CONF_PREFIX:-demo}"
CONF_DOMAIN="${CONF_PREFIX}.cloudydemo.com"
CONF_APPS_DOMAIN="apps.${CONF_PREFIX}.cloudydemo.com"

CONF_KEEP_HOSTNAME=true
CONF_KEEP_NAMESERVERS=true
CONF_NO_NTP=true
# During a kickstart you can tail the log file showing %post execution
# by using the following command:
#    tailf /mnt/sysimage/root/anaconda-post.log

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
  if [ -n "${!3}" ]; then
    eval $1=\${!3}
  elif is_true "$no_scramble" ; then
    eval $1=\$2
  else
    randomized=$(openssl rand -base64 20)
    eval $1=\${randomized//[![:alnum:]]}
  fi
  passwords[$1]="${!1}"
}

display_passwords()
{
  set +x
  for k in "${!passwords[@]}"; do
    out_string=""
    matching_var=""
    for postfix in password password1 pass; do
      vprefix=${k%${postfix}}
      [ "$vprefix" != "$k" ] && break
    done

    for v in "${vprefix}user" "${vprefix}user1"; do
      if [ "x${!v}" != "x" ]; then
        matchingvar=$v
        break
      fi
    done

    local -A subs
    subs[openshift]="OpenShift"
    subs[mcollective]="MCollective"
    subs[mongodb]="MongoDB"
    subs[activemq]="ActiveMQ"

    formattedprefix=${vprefix//_/ }
    for s in ${!subs[@]}; do
      formattedprefix=${formattedprefix//${s}/${subs[$s]}}
    done

    out_string+="$formattedprefix"
    [ "x$matchingvar" != "x" ] && out_string+=" ${matchingvar##*_}: ${!matchingvar}"
    [ "$vprefix" != "$k" ] && out_string+=" ${k##*_}"
    out_string+=": ${!k}"
    echo $out_string
  done
  set -x
}

configure_repos()
{
  echo "OpenShift: Begin configuring repos."
  # Determine which channels we need and define corresponding predicate
  # functions.

  # Make need_${repo}_repo return false by default.
  for repo in optional infra node client_tools extra \
              fuse_cartridge amq_cartridge jbosseap_cartridge jbosseap jbossews; do
      eval "need_${repo}_repo() { false; }"
  done

  is_true "$CONF_OPTIONAL_REPO" && need_optional_repo() { :; }

  if [ -n "${jbossews_extra_repo}${jbosseap_extra_repo}${rhel_optional_repo}${rhscl_extra_repo}${fuse_extra_repo}${amq_extra_repo}" ]; then
    need_extra_repo() { :; }
  fi

  if activemq || broker || datastore || named; then
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

  if node; then
    # The ose-node channel has node packages including all the cartridges.
    need_node_repo() { :; }

    # The jbosseap and jbossas cartridges require the jbossas packages
    # in the jbappplatform channel.
    is_true "${need_jbosseap}" \
             && need_jbosseap_cartridge_repo() { :; } \
             && need_jbosseap_repo() { :; }

    # The jbossews cartridge requires the tomcat packages in the jb-ews channel.
    is_true "${need_jbossews}" && need_jbossews_repo() { :; }

    # The fuse/amq cartridges require their own channels.
    is_true "${need_fuse}" && need_fuse_cartridge_repo() { :; }
    is_true "${need_amq}" && need_amq_cartridge_repo() { :; }

    # The rhscl channel is needed for several cartridge platforms.
    need_rhscl_repo() { :; }
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

  echo "OpenShift: Completed configuring repos."
}

configure_yum_repos()
{
#  configure_rhel_repo
  need_optional_repo && configure_optional_repo
  need_rhscl_repo && configure_rhscl_repo
  configure_ose_yum_repos
  configure_cart_repos
  configure_extra_repos
  yum clean metadata
  yum_install_or_exit openshift-enterprise-release
}

configure_ose_yum_repos()
{ # define plain yum repos if the parameters are given
  # this can be useful even if the main subscription is via RHN
  for repo in infra node jbosseap_cartridge client_tools; do
    if [ "$ose_repo_base" != "" ]; then
      layout=puddle; [ -n "$CONF_CDN_LAYOUT" ] && layout=cdn
      eval "need_${repo}_repo && def_ose_yum_repo $ose_repo_base $layout $repo"
    fi
    if [ "$ose_extra_repo_base" != "" ]; then
      eval "need_${repo}_repo && def_ose_yum_repo $ose_extra_repo_base extra $repo"
    fi
  done
}

configure_rhel_repo()
{
  # In order for the %post section to succeed, it must have a way of
  # installing from RHEL. The post section cannot access the method that
  # was used in the base install. This configures a RHEL yum repo which
  # you must supply.
if [ "${rhel_repo}x" != "x" ]; then
  cat > /etc/yum.repos.d/rhel.repo <<YUM
[rhel6]
name=RHEL 6 base OS
baseurl=${rhel_repo}
enabled=1
gpgcheck=0
sslverify=false
priority=20
sslverify=false
exclude=tomcat6* ${CONF_YUM_EXCLUDE_PKGS}

YUM
fi
}

configure_optional_repo()
{
if [ "${rhel_optional_repo}x" != "x" ]; then
  cat > /etc/yum.repos.d/rheloptional.repo <<YUM
[rhel6_optional]
name=RHEL 6 Optional
baseurl=${rhel_optional_repo}
enabled=1
gpgcheck=0
sslverify=false
priority=20
sslverify=false
exclude= ${CONF_YUM_EXCLUDE_PKGS}

YUM
fi
}

def_ose_yum_repo()
{
  repo_base=$1
  layout=$2  # one of: puddle, extra, cdn
  channel=$3 # one of: client_tools, infra, node, jbosseap_cartridge

  declare -A map
  case $layout in
  puddle | extra)
    map=([client_tools]=RHOSE-CLIENT-2.2 [infra]=RHOSE-INFRA-2.2 [node]=RHOSE-NODE-2.2 [jbosseap_cartridge]=RHOSE-JBOSSEAP-2.2)
    url="$repo_base/${map[$channel]}/x86_64/os/"
    ;;
  cdn | * )
    map=([client_tools]=ose-rhc [infra]=ose-infra [node]=ose-node [jbosseap_cartridge]=ose-jbosseap)
    url="$repo_base/${map[$channel]}/2.2/os"
    ;;
  esac
  cat > "/etc/yum.repos.d/openshift-${channel}-${layout}.repo" <<YUM
[openshift_${channel}_${layout}]
name=OpenShift $channel $layout
baseurl=$url
enabled=1
gpgcheck=0
sslverify=false
priority=10
sslverify=false
exclude= ${CONF_YUM_EXCLUDE_PKGS}

YUM
}

configure_rhscl_repo()
{
  if [ "x${rhscl_repo_base}" != "x" ]; then
    cat <<YUM > /etc/yum.repos.d/rhscl.repo
[rhscl]
name=rhscl
baseurl=${rhscl_repo_base}/rhscl/1/os/
enabled=1
priority=10
gpgcheck=0
sslverify=false
exclude= ${CONF_YUM_EXCLUDE_PKGS}

YUM

  fi
}

configure_cart_repos()
{ # add cartridge (or dependency) repo as needed
  local -A url=(
          [jbosseap]="${jboss_repo_base}/jbeap/6/os"
          [jbossews]="${jboss_repo_base}/jbews/2/os"
    [fuse_cartridge]="${jboss_repo_base}/ose-jbossfuse/2.2/os"
     [amq_cartridge]="${jboss_repo_base}/ose-jbossamq/2.2/os"
  )
  # Using jboss_repo_base for amq/fuse might seem a little odd in the future;
  # in which case, add a repo base just for them. Use extras if needed for now.

  local repo
  for repo in "${!url[@]}"; do
    eval "need_${repo}_repo" || continue
    cat <<YUM > "/etc/yum.repos.d/${repo}.repo"
[${repo}]
name=${repo}
baseurl=${url[$repo]}
enabled=1
gpgcheck=0
sslverify=false
priority=30
sslverify=false
exclude= ${CONF_YUM_EXCLUDE_PKGS}

YUM
  done
}

configure_extra_repos()
{ # add all defined extra repos in one file
  extra_repo_file=/etc/yum.repos.d/ose_extra.repo
  if [ -e "${extra_repo_file}" ]; then
      echo > "${extra_repo_file}"
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
  for repo in "${!priority[@]}"; do
    local url=$(eval echo '${'$repo'}')
    if [ "${url}x" != "x" ]; then
      cat <<YUM >> "${extra_repo_file}"
[${repo}]
name=${repo}
baseurl=${url}
enabled=1
gpgcheck=0
sslverify=false
priority=${priority[$repo]}
sslverify=false
exclude=${exclude[$repo]} ${CONF_YUM_EXCLUDE_PKGS}

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

   roles=""  # we will build the list of roles we need, then enable them.
   need_infra_repo && roles="$roles --role broker"
   need_client_tools_repo && roles="$roles --role client"
   need_node_repo && roles="$roles --role node"
   need_jbosseap_cartridge_repo && roles="$roles --role node-eap"
   need_fuse_cartridge_repo && roles="$roles --role node-fuse"
   need_amq_cartridge_repo && roles="$roles --role node-amq"
   oo-admin-yum-validator -o 2.2 --fix-all $roles # when fixing, rc is always false
   oo-admin-yum-validator -o 2.2 $roles || abort_install # so check when fixes are done

   # Normally we could just install o-e-release and it would pull in yum-validator;
   # however it turns out the ruby dependencies can sometimes be pulled in from the
   # wrong channel before yum-validator does its work. So, install it afterward.
   yum_install_or_exit openshift-enterprise-release
   configure_ose_yum_repos # refresh if overwritten by validator
   need_extra_repo && configure_extra_repos
}

configure_rhn_channels()
{
  if [ "x$CONF_RHN_REG_ACTKEY" != x ]; then
    echo "OpenShift: Register to RHN Classic using an activation key"
    eval "rhnreg_ks --force --activationkey=${CONF_RHN_REG_ACTKEY} --profilename='$profile_name' ${CONF_RHN_REG_OPTS}" || abort_install
  elif [[ "${CONF_RHN_USER}" && "${CONF_RHN_PASS}" ]]
  then
    echo "OpenShift: Register to RHN Classic with username and password"
    set +x # don't log password
    echo "rhnreg_ks --force --profilename='$profile_name' --username '${CONF_RHN_USER}' ${CONF_RHN_REG_OPTS}"
    eval "rhnreg_ks --force --profilename='$profile_name' --username '${CONF_RHN_USER}' --password '${CONF_RHN_PASS}' ${CONF_RHN_REG_OPTS}" || abort_install
    set -x
  else
    echo "OpenShift: No credentials given for RHN Classic; assuming already configured"
  fi

  if [[ "${CONF_RHN_USER}" && "${CONF_RHN_PASS}" ]]
  then
    # Enable the node or infrastructure channel to enable installing the release RPM
    repos=('rhel-x86_64-server-6-rhscl-1')
    if ! need_node_repo || need_infra_repo ; then
      repos+=('rhel-x86_64-server-6-ose-2.2-infrastructure')
    fi
    need_node_repo && repos+=('rhel-x86_64-server-6-ose-2.2-node' 'jb-ews-2-x86_64-server-6-rpm')
    need_client_tools_repo && repos+=('rhel-x86_64-server-6-ose-2.2-rhc')
    need_jbosseap_cartridge_repo && repos+=('rhel-x86_64-server-6-ose-2.2-jbosseap' 'jbappplatform-6-x86_64-server-6-rpm')
    need_fuse_cartridge_repo && repos+=('rhel-x86_64-server-6-ose-2.2-jbossfuse')
    need_amq_cartridge_repo && repos+=('rhel-x86_64-server-6-ose-2.2-jbossamq')

    set +x # don't log password
    for repo in "${repos[@]}"; do
      [[ "$(rhn-channel -l)" == *"$repo"* ]] || rhn-channel --add --channel "$repo" --user "${CONF_RHN_USER}" --password "${CONF_RHN_PASS}" || abort_install
    done
    set -x
  fi

  configure_subscription
}

configure_rhsm_channels()
{
  if [[ "${CONF_RHN_USER}" && "${CONF_RHN_PASS}" ]]
  then
    set +x # don't log password
    echo "OpenShift: Register with RHSM"
    echo "subscription-manager register --force --username='$CONF_RHN_USER' --name '$profile_name' ${CONF_RHN_REG_OPTS}"
    eval "subscription-manager register --force --username='$CONF_RHN_USER' --password='$CONF_RHN_PASS' --name '$profile_name' ${CONF_RHN_REG_OPTS}" || abort_install
    set -x
  else
    echo "OpenShift: No credentials given for RHSM; assuming already configured"
  fi

  if [[ "${CONF_SM_REG_POOL}" ]]
  then
    echo "OpenShift: Removing all current subscriptions"
    subscription-manager remove --all
  else
    echo "OpenShift: No pool ids were given, so none are being registered"
  fi

  # If CONF_SM_REG_POOL was not specified, this for loop is a no-op.
  for poolid in ${CONF_SM_REG_POOL//[, :+\/-]/ }; do
    echo "OpenShift: Registering subscription from pool id $poolid"
    subscription-manager attach --pool "$poolid" || abort_install
  done

  # Enable the node or infrastructure repo to enable installing the release RPM
  if need_node_repo; then subscription-manager repos --enable=rhel-6-server-ose-2.2-node-rpms || abort_install
  else subscription-manager repos --enable=rhel-6-server-ose-2.2-infra-rpms || abort_install
  fi
  configure_subscription
}

abort_install()
{
  [[ "$@"x == x ]] || echo "$@"
  # don't change this; could be used as an automation cue.
  echo "OpenShift: Aborting Installation."
  exit 1
}

yum_install_or_exit()
{
  echo "OpenShift: yum install $*"
  COUNT=0
  time while true; do
    yum install -y $* $disable_plugin
    if [ $? -eq 0 ]; then
      return
    elif [ $COUNT -gt 3 ]; then
      echo "OpenShift: Command failed: yum install $*"
      echo "OpenShift: Please ensure relevant repos/subscriptions are configured."
      abort_install
    fi
    let COUNT+=1
  done
}

# Install the client tools.
install_rhc_pkg()
{
  yum_install_or_exit rhc
}

# Set up the system express.conf so our broker will be used by default.
configure_rhc()
{
  # set_conf expects there to be a new line
  echo "" >> /etc/openshift/express.conf

  # set up the system express.conf so this broker will be used by default
  set_conf /etc/openshift/express.conf libra_server "'${broker_hostname}'"
}

# Install broker-specific packages.
install_broker_pkgs()
{
  local pkgs="openshift-origin-broker"
  pkgs="$pkgs openshift-origin-broker-util"
  pkgs="$pkgs rubygem-openshift-origin-msg-broker-mcollective"
  pkgs="$pkgs ruby193-mcollective-client"
  pkgs="$pkgs rubygem-openshift-origin-auth-remote-user"
  pkgs="$pkgs rubygem-openshift-origin-dns-nsupdate"
  pkgs="$pkgs openshift-origin-console"
  pkgs="$pkgs rubygem-openshift-origin-admin-console"
  is_true "$CONF_ROUTING_PLUGIN" && pkgs="$pkgs rubygem-openshift-origin-routing-activemq"

  # We use semanage in configure_selinux_policy_on_broker, so we need to
  # install policycoreutils-python.
  pkgs="$pkgs policycoreutils-python"

  yum_install_or_exit $pkgs
}

# Install node-specific packages.
install_node_pkgs()
{
  local pkgs="rubygem-openshift-origin-node ruby193-rubygem-passenger-native"
  pkgs="$pkgs openshift-origin-node-util"
  pkgs="$pkgs ruby193-mcollective openshift-origin-msg-node-mcollective"

  # We use semanage in configure_selinux_policy_on_node, so we need to
  # install policycoreutils-python.
  pkgs="$pkgs policycoreutils-python"

  pkgs="$pkgs rubygem-openshift-origin-container-selinux"
  pkgs="$pkgs rubygem-openshift-origin-frontend-nodejs-websocket"
  pkgs="$pkgs rubygem-openshift-origin-frontend-haproxy-sni-proxy"
  # technically not needed unless $CONF_SYSLOG includes gears, but it
  # does not hurt to have them available:
  if [[ "$CONF_SYSLOG" = *gears* ]]; then
    if rpm -q rsyslog ; then
      # RHEL 6.6's rsyslog7 package conflicts with the originaly RHEL 6 package
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
      echo "Invalid value: CONF_NODE_APACHE_FRONTEND=${node_apache_frontend}"
      abort_install
      ;;
  esac

  yum_install_or_exit $pkgs
}

# Remove abrt-addon-python if necessary
# https://bugzilla.redhat.com/show_bug.cgi?id=907449
# This only affects the python v2 cart
remove_abrt_addon_python()
{
  if grep 'Enterprise Linux Server release 6.4' /etc/redhat-release && rpm -q abrt-addon-python && rpm -q openshift-origin-cartridge-python; then
    yum $disable_plugin remove -y abrt-addon-python || abort_install
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
  p[all]="${all[@]}"
  p[premium]="${premium[@]}"
  p[stdframework]="${stdframework[@]}"
  p[stdaddon]="${stdaddon[@]}"
  p[standard]="${stdframework[@]} ${stdaddon[@]}"
  p[jboss]="${p[jbossews]} ${p[jbosseap]}"
  p[postgres]="${p[postgresql]}"

  # Build the list of packages to install ($pkgs) based on the list of
  # cartridges that the user instructs us to install ($cartridges).  See
  # the documentation on the CONF_CARTRIDGES / cartridges options for
  # the rules governing how $cartridges will be passed.
  local pkgs=( )
  for cart_spec in ${cartridges//,/ }
  do
    if [[ "${cart_spec:0:1}" = - ]]
    then
      # Remove every package indicated by the cart_spec, or remove the package
      # with name equal to $cart_spec itself if the cart_spec does not map to
      # anything in $p.
      for pkg in ${p[${cart_spec:1}]:-${cart_spec:1}}
      do
        for k in ${!pkgs[@]}
        do [[ ${pkgs[$k]} = $pkg ]] && unset "pkgs[$k]"
        done
      done
    else
      # Append all packages indicated by the cart_spec, or append
      # $cart_spec itself if it does not map to anything in $p.
      pkgs+=( ${p[$cart_spec]:-$cart_spec} )
    fi
  done

  if metapkgs_optional || metapkgs_recommended
  then
    for metapkg in ${meta[@]}
    do
      if [[ "${pkgs[@]}" =~ "-${metapkg}" ]]
      then
        metapkgs_optional && pkgs+=( "openshift-origin-cartridge-dependencies-optional-${metapkg}" )
        metapkgs_recommended && pkgs+=( "openshift-origin-cartridge-dependencies-recommended-${metapkg}" )
      fi
    done
  fi

  # Set need_<cart>=1 if $pkgs includes the relevant cartridge,
  # need_<cart>=0 otherwise, so that configure_repos will enable
  # only the appropriate channels.
  need_jbosseap=0; [[ "${pkgs[@]}" = *"${p[jbosseap]}"* ]] && need_jbosseap=1
  need_jbossews=0; [[ "${pkgs[@]}" = *"${p[jbossews]}"* ]] && need_jbossews=1
    # fuse is "special" because there's also a fuse-builder cart that can be used with
    # either fuse or amq and doesn't necessarily imply either. It comes from either of
    # those two channels; assume if desired they will have one of those channels already.
  need_fuse=0;     [[ "${pkgs[@]}" =~ openshift-origin-cartridge-fuse( |$) ]] && need_fuse=1
  need_amq=0;      [[ "${pkgs[@]}" = *"${p[amq]}"* ]] && need_amq=1

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

  yum_install_or_exit "${install_cart_pkgs}"
}

# Given the filename of a configuration file, the name of a setting,
# and a value, check whether the configuration file already assigns the
# given value to the setting.  If it does not, then comment out any
# existing setting and add the given setting.
#
# The search pattern is /^\s*name\s*=\s*value\s*(|#.*)$/.  The
# added line will be in the form 'name = value' or, if a short comment
# is specified, 'name = value # short comment'.  If a long comment is
# specified, a blank line followed by '# long comment' will be added
# before the line for the setting itself.
#
# $1 = configuration file's filename
# $2 = setting name
# $3 = value
# $4 = short comment (optional)
# $5 = long comment (optional)
set_conf()
{
  if ! grep -q "^\\s*$2\\s*=\\s*$3\\s*\\(\\|#.*\\)$" "$1"
  then
    sed -i -e "s/^\\s*$2\\s*=\\s*/#&/" "$1"
    if [[ -n "$5" ]]
    then
      echo >> "$1"
      echo "# $5" >> "$1"
    fi
    echo "$2 = $3${4:+ #$4}" >> "$1"
  fi
}

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

  restorecon -rv /var/run
  # This should cover everything in the SCL, including passenger
  time restorecon -rv /opt
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


  restorecon -rv /var/run
  time restorecon -rv /var/lib/openshift /etc/httpd/conf.d/openshift
  # disallow gear users from seeing what other gears exist
  chmod 0751 /var/lib/openshift
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
}

configure_quotas_on_node()
{
  # Get the mountpoint for /var/lib/openshift (should be /).
  geardata_mnt=$(df -P /var/lib/openshift 2>/dev/null | tail -n 1 | awk '{ print $6 }')

  if ! [ x"$geardata_mnt" != x ]
  then
    echo 'Could not enable quotas for gear data: unable to determine mountpoint.'
  else
    # Enable user quotas for the filesystem housing /var/lib/openshift.
    sed -i -e "/^[^[:blank:]]\\+[[:blank:]]\\+${geardata_mnt////\/}[[:blank:]]/{/usrquota/! s/[[:blank:]]\\+/,usrquota&/4;}" /etc/fstab
    # Remount to enable quotas immediately.
    mount -o remount "${geardata_mnt}"

    # External mounts, esp. at /var/lib/openshift, may often be created
    # with an incorrect context and quotacheck hits SElinux denials.
    time restorecon "${geardata_mnt}"
    # Generate user quota info for the mount point.
    time quotacheck -cmug "${geardata_mnt}"
    # fix up selinux label on created quota file
    restorecon "${geardata_mnt}"/aquota.user

    # (re)enable quotas
    time quotaon "${geardata_mnt}"
  fi
}

configure_idler_on_node()
{
  [[ "$CONF_IDLE_INTERVAL" =~ ^[[:digit:]]+$ ]] || return
  cat <<CRON > /etc/cron.hourly/auto-idler
(
  /usr/sbin/oo-last-access
  /usr/sbin/oo-auto-idler idle --interval $CONF_IDLE_INTERVAL
) >> /var/log/openshift/node/auto-idler.log 2>&1
CRON
  chmod +x /etc/cron.hourly/auto-idler
}

# $1 = setting name
# $2 = value
# $3 = long comment
set_sysctl()
{
  set_conf /etc/sysctl.conf "$1" "$2" '' "$3"
}

# Turn some sysctl knobs.
configure_sysctl_on_node()
{
  set_sysctl kernel.sem '250  32000 32  4096' 'Accomodate many httpd instances for OpenShift gears.'

  set_sysctl net.ipv4.ip_local_port_range '15000 35530' 'Move the ephemeral port range to accomodate the OpenShift port proxy.'

  set_sysctl net.netfilter.nf_conntrack_max 1048576 'Increase the connection tracking table size for the OpenShift port proxy.'

  set_sysctl net.ipv4.ip_forward 1 'Enable forwarding for the OpenShift port proxy.'

  set_sysctl net.ipv4.conf.all.route_localnet 1 'Allow the OpenShift port proxy to route using loopback addresses.'

  # As recommended elsewhere and investigated at length in https://bugzilla.redhat.com/show_bug.cgi?id=1085115
  # this is a safe, effective way to keep lots of short requests from exhausting the connection table.
  set_sysctl net.ipv4.tcp_tw_reuse 1 'Reuse closed connections quickly.' 
}


configure_sshd_on_node()
{
  # Configure sshd to pass the GIT_SSH environment variable through.
  # The newline is needed because cloud-init doesn't add a newline after the
  # configuration it adds.
  printf '\nAcceptEnv GIT_SSH' >> /etc/ssh/sshd_config

  # Up the limits on the number of connections to a given node.
  sed -i -e "s/^#MaxSessions .*$/MaxSessions 40/" /etc/ssh/sshd_config
  sed -i -e "s/^#MaxStartups .*$/MaxStartups 40/" /etc/ssh/sshd_config

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
# $2 = regex to test output
# $3 = user
# $4 = password
execute_mongodb()
{
  echo "Running commands on MongoDB:"
  echo "---"
  echo "$1"
  echo "---"

  if [ -n "$3" -a -n "$4" ]; then
    userpass="-u ${3} -p ${4} admin"
  else
    userpass=""
  fi

  output="$( echo "$1" | mongo ${userpass} )"
  echo "$output"
  if [ "$2" ]; then # test output against regex
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
    if [[ ${datastore_replicants} =~ , ]]
    then
      echo 'while (rs.isMaster().primary == null) { sleep(5); }'
    fi
    if is_false "$CONF_NO_DATASTORE_AUTH_FOR_LOCALHOST"
    then
      # Add an administrative user.
      echo 'use admin'
      echo "db.addUser('${mongodb_admin_user}', '${mongodb_admin_password}')"
      echo "db.auth('${mongodb_admin_user}', '${mongodb_admin_password}')"
    fi

    # Add the user that the broker will use.
    echo "use ${mongodb_name}"
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
    abort_install "OpenShift: Failed to form MongoDB replica set; please do this manually."

  master_out="$(echo 'while (rs.isMaster().primary == null) { sleep(5); }; print("host="+rs.isMaster().primary)' | mongo | grep 'host=')" ||
    abort_install "OpenShift: Failed to query the MongoDB replica set master; please verify the replica set configuration manually."

  configure_datastore_add_users

  # Configure the replica set.
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
        if echo "" | mongo $replicant
        then
          break
        fi
        sleep 60
      done

      time execute_mongodb "rs.add(\"${replicant}\")" '"ok" : 1' ${mongodb_admin_user} ${mongodb_admin_password} ||
        abort_install "OpenShift: Failed to add ${replicant} to replica set; please verify the replica set manually"
    fi
  done

  set -x
}

# $1 = setting name
# $2 = value
set_mongodb()
{
  set_conf /etc/mongodb.conf "$1" "$2"
}

configure_datastore()
{
  # Require authentication.
  set_mongodb auth true

  # Use a smaller default size for databases.
  set_mongodb smallfiles true

  if [[ ${datastore_replicants} =~ , ]]
  then
    # This mongod will be part of a replicated setup.

    # Enable the REST API.
    set_mongodb rest true

    # Enable journaling for writes.
    set_mongodb journal true

    # Enable replication.
    set_mongodb replSet "${mongodb_replset}"

    # Configure a key for the replica set.
    set_mongodb keyFile /etc/mongodb.keyfile

    rm -f /etc/mongodb.keyfile
    echo "${mongodb_key}" > /etc/mongodb.keyfile
    chown -v mongodb.mongodb /etc/mongodb.keyfile
    chmod -v 400 /etc/mongodb.keyfile
  fi

  # If mongod is running on a separate host from the broker OR
  # we are configuring a replica set, open up the firewall to allow
  # other broker or datastore hosts to connect.
  if broker && ! [[ ${datastore_replicants} =~ , ]]
  then
    echo 'The broker and data store are on the same host.'
    echo 'Skipping firewall and mongod configuration;'
    echo 'mongod will only be accessible over localhost.'
  else
    echo 'The data store needs to be accessible externally.'

    echo 'Configuring the firewall to allow connections to mongod...'
    firewall_allow[mongodb]=tcp:27017

    echo 'Configuring mongod to listen on all interfaces...'
    set_mongodb bind_ip 0.0.0.0
  fi

  # Configure mongod to start on boot.
  chkconfig mongod on

  # Start mongod so we can perform some administration now.
  service mongod start

  if ! [[ ${datastore_replicants} =~ , ]]
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
:rhc-app-comm - [0:0]' /etc/sysconfig/iptables
  sed -i '/-A INPUT -i lo -j ACCEPT/a \
-A INPUT -j rhc-app-comm' /etc/sysconfig/iptables
}

configure_gears()
{
  # Make sure that gears are restarted on reboot.
  chkconfig openshift-gears on

  # configure gear logging
  if [[ "$CONF_SYSLOG" = *gears* ]]; then
    # make the gear app servers log to syslog by default (overrideable)
    sed -i -e '
      /outputtype\b/I coutputType = syslog
      /outputtypefromenviron/I coutputTypeFromEnviron = true
    ' /etc/openshift/logshifter.conf
    # use rsyslog7 so we can annotate
    # disable some of the stock options shipped
    sed -i -e '
      /ModLoad imuxsock/ s/^/#/     # will load separately with custom options
      /var\/log\/messages/ s/^/#/   # disable original messages log
      /ModLoad imjournal/ s/^/#/    # imjournal module is not even available...
      /IMJournalStateFile/ s/^/#/
      /OmitLocalLogging/ s/^/#/
    ' /etc/rsyslog.conf
    # enable custom log format via imuxsock
    cat <<'LOGCONF' >> /etc/rsyslog.d/imuxsock-and-openshift-gears.conf
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
    configure_mmopenshift_selinux_policy
    chkconfig rsyslog on
    service rsyslog restart
  fi
}

configure_mmopenshift_selinux_policy()
{
  local req=selinux-policy-3.7.19-237.el6.noarch # no need if policy update released
  [[ $(rpm -q selinux-policy | sed "i$req" | sort -V | head -1 ) == $req ]] && return
  echo "Installing SELinux policy module for rsyslog7-mmopenshift per BZ 1096155"
  local dir=$(mktemp -d /tmp/selinux.XXXXXXXX)
  pushd $dir
    cat <<POLICY > rsyslog7-mmopenshift.te

module rsyslog7-mmopenshift 1.0;
require {
        type syslogd_t;
        type inotifyfs_t;
        class dir read;
}
#============= syslogd_t ==============
# enable rsyslog7-mmopenshift to receive inotify events so that when
# a gear is removed, context for its UID is cleared from module cache.
allow syslogd_t inotifyfs_t:dir read;
POLICY
    checkmodule -M -m -o rsyslog7-mmopenshift.mod rsyslog7-mmopenshift.te
    semodule_package -o rsyslog7-mmopenshift.pp -m rsyslog7-mmopenshift.mod
    semodule -i rsyslog7-mmopenshift.pp
  popd
  "rm" -r $dir
}


# Enable services to start on boot for the node.
enable_services_on_node()
{
  firewall_allow[https]=tcp:443
  firewall_allow[http]=tcp:80

  # Allow connections to openshift-node-web-proxy
  firewall_allow[ws]=tcp:8000
  firewall_allow[wss]=tcp:8443

  # Allow connections to openshift-sni-proxy
  if is_true "$enable_sni_proxy"; then
    firewall_allow[sni]="tcp:${sni_first_port}:${sni_last_port}"
    chkconfig openshift-sni-proxy on
  else
    chkconfig openshift-sni-proxy off
  fi

  chkconfig httpd on
  chkconfig network on
  is_false "$CONF_NO_NTP" && chkconfig ntpd on
  chkconfig sshd on
  chkconfig oddjobd on
  chkconfig openshift-node-web-proxy on
  chkconfig openshift-watchman on
}


# Enable services to start on boot for the broker and fix up some issues.
enable_services_on_broker()
{
  firewall_allow[https]=tcp:443
  firewall_allow[http]=tcp:80

  chkconfig httpd on
  chkconfig network on
  is_false "$CONF_NO_NTP" && chkconfig ntpd on
  chkconfig sshd on
}


generate_mcollective_pools_configuration()
{
  num_replicants=0
  members=
  for replicant in ${activemq_replicants//,/ }
  do
    let num_replicants=num_replicants+1
    new_member="plugin.activemq.pool.${num_replicants}.host = ${replicant}
plugin.activemq.pool.${num_replicants}.port = 61613
plugin.activemq.pool.${num_replicants}.user = ${mcollective_user}
plugin.activemq.pool.${num_replicants}.password = ${mcollective_password}
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
  MCOLLECTIVE_CFG="/opt/rh/ruby193/root/etc/mcollective/client.cfg"
  cat <<EOF > $MCOLLECTIVE_CFG
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

  chown apache:apache $MCOLLECTIVE_CFG
  chmod 640 $MCOLLECTIVE_CFG

  # make sure mcollective client log is created with proper ownership.
  # if root owns it, the broker (apache user) can't log to it.
  touch /var/log/openshift/broker/ruby193-mcollective-client.log
  chown apache:root /var/log/openshift/broker/ruby193-mcollective-client.log

  RESTART_NEEDED=true
}


# Configure mcollective on the node to use ActiveMQ.
configure_mcollective_for_activemq_on_node()
{
  cat <<EOF > /opt/rh/ruby193/root/etc/mcollective/server.cfg
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
  for replicant in ${activemq_replicants//,/ }
  do
    if ! [ "$replicant" = "$activemq_hostname" ]
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
  if is_true "${CONF_ROUTING_PLUGIN}"
  then
    schedulerSupport='schedulerSupport="true"'
    IFS= read -r -d '' routingPolicy <<'EOF'
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
               ${authenticationUser_amq}
               <authenticationUser username="admin" password="${activemq_admin_password}" groups="mcollective,admin,everyone"/>
               $( if is_true "$CONF_ROUTING_PLUGIN"; then
                    echo "<authenticationUser username=\"$routing_plugin_user\" password=\"$routing_plugin_pass\" groups=\"routinginfo,everyone\"/>"
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
                  $( if is_true "$CONF_ROUTING_PLUGIN"; then
                       echo '<authorizationEntry topic="routinginfo.>" write="routinginfo" read="routinginfo" admin="routinginfo" />'
                       echo '<authorizationEntry queue="routinginfo.>" write="routinginfo" read="routinginfo" admin="routinginfo" />'
                     fi
                  )
                </authorizationEntries>
              </authorizationMap>
            </map>
          </authorizationPlugin>
${routingPolicy}
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
  firewall_allow[stomp]=tcp:61613
  allow_openwire && firewall_allow[openwire]=tcp:61616

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
  rndc-confgen -a -r /dev/urandom
  restorecon /etc/rndc.* /etc/named.*
  chown root:named /etc/rndc.key
  chmod 640 /etc/rndc.key

  # Set up DNS forwarding if so directed.
  forwarders="recursion no;"
  if is_true "$CONF_FORWARD_DNS"; then
    echo "forwarders { ${nameservers} } ;" > /var/named/forwarders.conf
    restorecon /var/named/forwarders.conf
    chmod 644 /var/named/forwarders.conf
    forwarders='// set forwarding to the next nearest server (from DHCP response)
	forward only;
        include "forwarders.conf";
	recursion yes;
'
  fi

  # Install the configuration file for the OpenShift Enterprise domain
  # name.
  rm -rf /var/named/dynamic
  mkdir -p /var/named/dynamic

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
  chown root:named /etc/named.conf
  chcon system_u:object_r:named_conf_t:s0 -v /etc/named.conf

  # actually set up the domain zone(s)
  # bind_key is used if set, created if not. both domains use same key.
  configure_named_zone "$hosts_domain"
  [ "$domain" != "$hosts_domain" ] && configure_named_zone "$domain"

  # configure in any hosts as needed
  configure_hosts_dns

  # Configure named to start on boot.
  firewall_allow[dns]=tcp:53,udp:53
  chkconfig named on

  # Start named so we can perform some updates immediately.
  service named start
}

configure_named_zone()
{
  zone="$1"

  if [ "x$bind_key" = x ]; then
    # Generate a new secret key
    zone_tolower="${zone,,}"
    rm -f /var/named/K${zone_tolower}*
    dnssec-keygen -a ${bind_keyalgorithm} -b ${bind_keysize} -n USER -r /dev/urandom -K /var/named ${zone}
    # $zone may have uppercase letters in it.  However the file that
    # dnssec-keygen creates will have the zone in lowercase.
    bind_key="$(grep Key: /var/named/K${zone_tolower}*.private | cut -d ' ' -f 2)"
    rm -f /var/named/K${zone_tolower}*
  fi

  # Install the key where BIND and oo-register-dns expect it.
  cat <<EOF > /var/named/${zone}.key
key ${zone} {
  algorithm "${bind_keyalgorithm}";
  secret "${bind_key}";
};
EOF

  # Create the initial BIND database.
  cat <<EOF > /var/named/dynamic/${zone}.db
\$ORIGIN .
\$TTL 1	; 1 seconds (for testing only)
${zone}		IN SOA	$named_hostname. hostmaster.$zone. (
				2011112904 ; serial
				60         ; refresh (1 minute)
				15         ; retry (15 seconds)
				1800       ; expire (30 minutes)
				10         ; minimum (10 seconds)
				)
				IN NS	$named_hostname.
				IN MX	10 mail.$zone.
\$ORIGIN ${zone}.
EOF

  # Add a record for the zone to named conf
  cat <<EOF >> /etc/named.conf
include "${zone}.key";

zone "${zone}" IN {
	type master;
	file "dynamic/${zone}.db";
	allow-update { key ${zone} ; } ;
};
EOF
}

ensure_domain()
{ # adds a domain to hostname if it does not have one
  # $1 = host; $2 = domain
  if [[ $1 == *.* ]]; then # already FQDN or IP
    echo "$1"
  else # needs a domain
    echo "$1.$2"
  fi
}

add_host_to_zone()
{
  # $1 = host; $2 = ip; [ $3 = zone ]
  zone="${3:-$hosts_domain}"
  nsdb="/var/named/dynamic/${zone}.db"
  # sanity check that $1 isn't an IP, and $2 is.
  ip_regex='^[.0-9]+$' # all numbers and dots = IP (not rigorous)
  if [[ $1 =~ $ip_regex || ! $2 =~ $ip_regex ]]; then
    echo "Not adding DNS record to host zone: '$1' should be a hostname and '$2' should be an IP address"
  else
    echo "${1%.${zone}}			IN A	$2" >> $nsdb
  fi
}

configure_hosts_dns()
{
  add_host_to_zone "$named_hostname" "$named_ip_addr" # always define self
  # glue record for NS host in subdomain:
  [[ "$hosts_domain" == *?"$domain" ]] && add_host_to_zone "$named_hostname" "$named_ip_addr" "$domain"
  if [ -z "$CONF_NAMED_ENTRIES" ]; then
    # Add A records for any other components that are being installed locally.
    broker && add_host_to_zone "$broker_hostname" "$broker_ip_addr"
    node && add_host_to_zone "$node_hostname" "$node_ip_addr"
    activemq && add_host_to_zone "$activemq_hostname" "$cur_ip_addr"
    datastore && add_host_to_zone "$datastore_hostname" "$cur_ip_addr"
  elif [[ "$CONF_NAMED_ENTRIES" =~ : ]]; then
    # Add any A records for host:ip pairs passed in via CONF_NAMED_ENTRIES
    for host_ip in ${CONF_NAMED_ENTRIES//,/ }; do
      add_host_to_zone ${host_ip//:/ }
    done
  else # if "none" then just don't add anything
    echo "Not adding named entries; named_entries = $CONF_NAMED_ENTRIES"
  fi
}

# An alternate method for registering against a running named
# using oo-register-dns. Not used by default.
register_named_entries()
{
  ip_regex='^[.0-9]+$' # all numbers and dots = IP (not rigorous)
  failed="false"
  for host_ip in ${CONF_NAMED_ENTRIES//,/ }; do
    read host ip <<<$(echo ${host_ip//:/ })
    if [[ $host =~ $ip_regex || ! $ip =~ $ip_regex ]]; then
      echo "Not adding DNS record to host zone: '$host' should be a hostname and '$ip' should be an IP address"
    elif ! oo-register-dns -d "$hosts_domain" -h "${host%.$hosts_domain}" -k "${hosts_domain_keyfile}" -n $ip; then
      echo "WARNING: Failed to register host $host with IP $ip"
      failed="true"
    fi
  done
  is_false "$failed" && echo "OpenShift: Completed updating host DNS entries."
}

configure_network()
{
  # Ensure interface is configured to come up on boot
  sed -i -e 's/ONBOOT="no"/ONBOOT="yes"/' /etc/sysconfig/network-scripts/ifcfg-$interface

  # Check if static IP configured
  if grep -q "IPADDR" /etc/sysconfig/network-scripts/ifcfg-$interface; then
    sed -i -e 's/BOOTPROTO="dhcp"/BOOTPROTO="none"/' /etc/sysconfig/network-scripts/ifcfg-$interface
    sed -i -e 's/IPV6INIT="yes"/IPV6INIT="no"/' /etc/sysconfig/network-scripts/ifcfg-$interface
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
  sed -i -e "/search/ d; 1i# The named we install for our OpenShift PaaS must appear first.\\nsearch ${hosts_domain}.\\nnameserver ${named_ip_addr}\\n" /etc/resolv.conf

  # Append resolution conf to the DHCP configuration.
  sed -i -e "/prepend domain-name-servers ${named_ip_addr};/d" /etc/dhcp/dhclient-$interface.conf
  sed -i -e "/prepend domain-search ${hosts_domain};/d" /etc/dhcp/dhclient-$interface.conf
  cat <<EOF >> /etc/dhcp/dhclient-$interface.conf

prepend domain-name-servers ${named_ip_addr};
prepend domain-search "${hosts_domain}";
EOF
}

update_controller_gear_size_configs()
{
  # Configure the valid gear sizes, default gear capabilities and default gear
  # size for the broker
  sed -i -e "s/^VALID_GEAR_SIZES=.*/VALID_GEAR_SIZES=\"${valid_gear_sizes}\"/" \
      -e "s/^DEFAULT_GEAR_CAPABILITIES=.*/DEFAULT_GEAR_CAPABILITIES=\"${default_gear_capabilities}\"/" \
      -e "s/^DEFAULT_GEAR_SIZE=.*/DEFAULT_GEAR_SIZE=\"${default_gear_size}\"/" \
      /etc/openshift/broker.conf

  RESTART_NEEDED=true
}

# Update the controller configuration.
configure_controller()
{
  if [ "x$broker_auth_salt" = "x" ]
  then
    echo "Warning: broker authentication salt is empty!"
  fi

  # Configure the broker with the correct domain name, and use random salt
  # to the data store (the host running MongoDB).
  sed -i -e "s/^CLOUD_DOMAIN=.*$/CLOUD_DOMAIN=${domain}/" \
      /etc/openshift/broker.conf
  echo AUTH_SALT=${broker_auth_salt} >> /etc/openshift/broker.conf

  update_controller_gear_size_configs

  # Configure the session secret for the broker
  sed -i -e "s/# SESSION_SECRET=.*$/SESSION_SECRET=${broker_session_secret}/" \
      /etc/openshift/broker.conf

  # Configure the session secret for the console
  if [ `grep -c SESSION_SECRET /etc/openshift/console.conf` -eq 0 ]
  then
    echo "SESSION_SECRET=${console_session_secret}" >> /etc/openshift/console.conf
  fi

  if [[ ${datastore_replicants} =~ , ]] || ! datastore
  then
    #mongo installed remotely or replicated, so configure with given hostname(s)
    sed -i -e "s/^MONGO_HOST_PORT=.*$/MONGO_HOST_PORT=\"${datastore_replicants}\"/" /etc/openshift/broker.conf
  fi

  # configure MongoDB access
  sed -i -e "s/MONGO_PASSWORD=.*$/MONGO_PASSWORD=\"${mongodb_broker_password}\"/
            s/MONGO_USER=.*$/MONGO_USER=\"${mongodb_broker_user}\"/
            s/MONGO_DB=.*$/MONGO_DB=\"${mongodb_name}\"/" \
      /etc/openshift/broker.conf

  # configure broker logs for syslog
  [[ "$CONF_SYSLOG" = *broker* ]] && \
    sed -i -e '/SYSLOG_ENABLED=/ cSYSLOG_ENABLED="true"' /etc/openshift/broker.conf
  [[ "$CONF_SYSLOG" = *console* ]] && \
    echo 'SYSLOG_ENABLED="true"' >> /etc/openshift/console.conf

  # Set the ServerName for httpd
  sed -i -e "s/ServerName .*$/ServerName ${hostname}/" \
      /etc/httpd/conf.d/000002_openshift_origin_broker_servername.conf

  # Configure the broker service to start on boot.
  chkconfig openshift-broker on
  chkconfig openshift-console on

  RESTART_NEEDED=true
}

configure_messaging_plugin()
{ # 1 optional arg - ports per gear
  local ports="${1:-$ports_per_gear}"
  local pool_size=6000
  let "pool_size=30000/$ports"

  local file=/etc/openshift/plugins.d/openshift-origin-msg-broker-mcollective.conf
  cp "$file"{.example,}
  sed -i -e "s/DISTRICTS_FIRST_UID=.*/DISTRICTS_FIRST_UID=${district_first_uid}/
             s/DISTRICTS_MAX_CAPACITY=.*/DISTRICTS_MAX_CAPACITY=${pool_size}/
            " $file
  RESTART_NEEDED=true
}

# Configure the broker to use the BIND DNS plug-in.
configure_dns_plugin()
{
  if [ "x$bind_key" = x ] && [ "x$bind_krb_keytab" = x ]
  then
    echo 'WARNING: Neither key nor keytab has been set for communication'
    echo 'with BIND. You will need to modify the value of BIND_KEYVALUE'
    echo 'and BIND_KEYALGORITHM in /etc/openshift/plugins.d/openshift-origin-dns-nsupdate.conf'
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
BIND_KEYALGORITHM="${bind_keyalgorithm}"
EOF
  else
    cat <<EOF >> /etc/openshift/plugins.d/openshift-origin-dns-nsupdate.conf
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
  cp -p /etc/openshift/plugins.d/openshift-origin-auth-remote-user.conf{.example,}

  # Configure mod_auth_kerb if both CONF_BROKER_KRB_SERVICE_NAME
  # and CONF_BROKER_KRB_AUTH_REALMS are specified
  if [ -n "$CONF_BROKER_KRB_SERVICE_NAME" ] && [ -n "$CONF_BROKER_KRB_AUTH_REALMS" ]
  then
    yum_install_or_exit mod_auth_kerb
    for d in /var/www/openshift/broker/httpd/conf.d /var/www/openshift/console/httpd/conf.d
    do
      sed -e "s#KrbServiceName.*#KrbServiceName ${CONF_BROKER_KRB_SERVICE_NAME}#" \
        -e "s#KrbAuthRealms.*#KrbAuthRealms ${CONF_BROKER_KRB_AUTH_REALMS}#" \
	$d/openshift-origin-auth-remote-user-kerberos.conf.sample > $d/openshift-origin-auth-remote-user-kerberos.conf
    done
    return
  fi

  # Install the Apache Basic Authentication configuration file.
  cp -p /var/www/openshift/broker/httpd/conf.d/openshift-origin-auth-remote-user-basic.conf.sample \
     /var/www/openshift/broker/httpd/conf.d/openshift-origin-auth-remote-user.conf

  cp -p /var/www/openshift/console/httpd/conf.d/openshift-origin-auth-remote-user-basic.conf.sample \
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

  RESTART_NEEDED=true
}

configure_routing_plugin()
{
  if is_true "$CONF_ROUTING_PLUGIN"; then
    conffile=/etc/openshift/plugins.d/openshift-origin-routing-activemq.conf
    sed -e '/^ACTIVEMQ_\(USERNAME\|PASSWORD\|HOST\)/ d' $conffile.example > $conffile
    cat <<EOF >> "$conffile"
ACTIVEMQ_HOST='$activemq_replicants'
ACTIVEMQ_USERNAME='$routing_plugin_user'
ACTIVEMQ_PASSWORD='$routing_plugin_pass'
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
      # node vhost obscures the broker vhost with same ServerName; not really needed, so remove it.
      sed -i -e '/<VirtualHost \*:443>/,/<\/VirtualHost/ s/^/#/' /etc/httpd/conf.d/000001_openshift_origin_frontend_vhost.conf
      ;;
    mod_rewrite)
      # node vhost obscures the broker vhost still, but can let specific requests past
      cat <<EOF >> /var/lib/openshift/.httpd.d/nodes.txt
__default__ REDIRECT:/console
__default__/rsync_id_rsa.pub NOPROXY
__default__/console TOHTTPS:127.0.0.1:8118/console
__default__/broker TOHTTPS:127.0.0.1:8080/broker
__default__/admin-console TOHTTPS:127.0.0.1:8080/admin-console
__default__/assets TOHTTPS:127.0.0.1:8080/assets
EOF

      httxt2dbm -f DB -i /etc/httpd/conf.d/openshift/nodes.txt -o /etc/httpd/conf.d/openshift/nodes.db
      chown root:apache /etc/httpd/conf.d/openshift/nodes.txt /etc/httpd/conf.d/openshift/nodes.db
      chmod 750 /etc/httpd/conf.d/openshift/nodes.txt /etc/httpd/conf.d/openshift/nodes.db
      ;;
    *)
      echo "Invalid value: CONF_NODE_APACHE_FRONTEND=${node_apache_frontend}"
      abort_install
      ;;
  esac
}

configure_access_keys_on_broker()
{
  # Generate a broker access key for remote apps (Jenkins) to access
  # the broker.
  echo "${broker_auth_priv_key}" > /etc/openshift/server_priv.pem
  openssl rsa -in /etc/openshift/server_priv.pem -pubout > /etc/openshift/server_pub.pem
  chown apache:apache /etc/openshift/server_pub.pem
  chmod 640 /etc/openshift/server_pub.pem

  # If a key pair already exists, delete it so that the ssh-keygen
  # command will not have to ask the user what to do.
  rm -f /root/.ssh/rsync_id_rsa /root/.ssh/rsync_id_rsa.pub

  # Generate a key pair for moving gears between nodes from the broker
  ssh-keygen -t rsa -b 2048 -P "" -f /root/.ssh/rsync_id_rsa
  cp /root/.ssh/rsync_id_rsa* /etc/openshift/
  # the .pub key needs to go on nodes. So, we provide it via a standard
  # location on httpd:
  cp /root/.ssh/rsync_id_rsa.pub /var/www/html/
  # The node install script can retrieve this or it can be performed manually:
  #   # wget -q -O- --no-check-certificate https://${broker_hostname}/rsync_id_rsa.pub?host=${node_hostname} >> /root/.ssh/authorized_keys
  # In order to enable this during the install, we turn on httpd.
  service httpd start
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
OpenShift Enterprise default
Temporary certificate
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
OpenShift Enterprise default
Temporary certificate
${broker_hostname}
root@${domain}
EOF
}

# Set the hostname
configure_hostname()
{
  if [[ ! "$hostname" =~ ^[0-9.]*$ ]]  # hostname is not just an IP
  then
    sed -i -e "s/HOSTNAME=.*/HOSTNAME=${hostname}/" /etc/sysconfig/network
    hostname "${hostname}"
  fi
}

# Set some parameters in the OpenShift node configuration files.
configure_node()
{
  local resrc=/etc/openshift/resource_limits.conf
  if [[ -f "$resrc.${node_profile}.${node_host_type}" ]]; then
    cp "$resrc.${node_profile}.${node_host_type}" $resrc
  elif [[ -f "$resrc.${node_profile}" ]]; then
    cp "$resrc.${node_profile}" $resrc
  fi
  sed -i -e "s/^node_profile=.*$/node_profile=${node_profile_name}/" $resrc

  local conf=/etc/openshift/node.conf
  sed -i -e "s/^PUBLIC_IP=.*$/PUBLIC_IP=${node_ip_addr}/;
             s/^CLOUD_DOMAIN=.*$/CLOUD_DOMAIN=${domain}/;
             s/^PUBLIC_HOSTNAME=.*$/PUBLIC_HOSTNAME=${hostname}/;
             s/^BROKER_HOST=.*$/BROKER_HOST=${broker_hostname}/;
             s/^[# ]*EXTERNAL_ETH_DEV=.*$/EXTERNAL_ETH_DEV='${interface}'/" \
      $conf
  if [[ "$ports_per_gear" != 5 ]]; then
    sed -i -e "/PORTS_PER_USER=/ cPORTS_PER_USER=${ports_per_gear}" $conf
    # if not already there, we need to add it
    grep -q '^PORTS_PER_USER' $conf || sed -i -e "$ a\\
\\
# Number of proxy ports available per gear. Increasing the ports per gear requires reducing\\
# the number of UIDs the district has so that the ports allocated to all UIDs fit in the\\
# proxy port range.\\
PORTS_PER_USER=${ports_per_gear}
                                                 " $conf
  fi

  case "$node_apache_frontend" in
    mod_rewrite)
      sed -i -e "/OPENSHIFT_FRONTEND_HTTP_PLUGINS/ s/vhost/mod-rewrite/" $conf
      ;;
    vhost)
      sed -i -e "/OPENSHIFT_FRONTEND_HTTP_PLUGINS/ s/mod-rewrite/vhost/" $conf
      ;;
  esac

  if is_true "$enable_sni_proxy"; then
    # configure in the sni proxy
    grep -q 'OPENSHIFT_FRONTEND_HTTP_PLUGINS=.*sni-proxy' $conf || \
      sed -i -e '/OPENSHIFT_FRONTEND_HTTP_PLUGINS/ s/=/=openshift-origin-frontend-haproxy-sni-proxy,/' $conf
    local port_list=$(seq -s, "$sni_first_port" "$sni_last_port")
    sed -i -e "/PROXY_PORTS/ cPROXY_PORTS=${port_list}" /etc/openshift/node-plugins.d/openshift-origin-frontend-haproxy-sni-proxy.conf
  fi

  echo $broker_hostname > /etc/openshift/env/OPENSHIFT_BROKER_HOST
  echo $domain > /etc/openshift/env/OPENSHIFT_CLOUD_DOMAIN

  # Set the ServerName for httpd
  sed -i -e "s/ServerName .*$/ServerName ${hostname}/" \
      /etc/httpd/conf.d/000001_openshift_origin_node_servername.conf

  configure_node_logs
  RESTART_NEEDED=true
}

configure_node_logs()
{
  if [[ "$CONF_SYSLOG" = *node* ]]; then
    # send the node platform logs to syslog instead
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
    ' /etc/openshift/node.conf
    echo 'local0.*  /var/log/messages' > /etc/rsyslog.d/openshift-node-platform.conf
  fi
  if [[ "$CONF_SYSLOG" = *frontend* ]]; then
    # send the frontend logs to syslog (in addition to file)
    sed -i -e 's/^#*\s*OPTIONS="\?\([^"]*\)"\?/OPTIONS="\1 -DOpenShiftFrontendSyslogEnabled"/' /etc/sysconfig/httpd
  fi
  if is_true "$CONF_NODE_LOG_CONTEXT"; then
    # annotate the frontend logs with UUIDs
    sed -i -e '
      s/^.*PLATFORM_LOG_CONTEXT_ENABLED=.*/PLATFORM_LOG_CONTEXT_ENABLED=1/
      s/^.*PLATFORM_LOG_CONTEXT_ATTRS=.*/PLATFORM_LOG_CONTEXT_ATTRS=request_id,app_uuid,container_uuid/
    ' /etc/openshift/node.conf
    sed -i -e 's/^#*\s*OPTIONS="\?\([^"]*\)"\?/OPTIONS="\1 -DOpenShiftAnnotateFrontendAccessLog"/' /etc/sysconfig/httpd
  fi
  if [[ "$CONF_METRICS_INTERVAL" != "" ]]; then
    # configure watchman with given interval
    sed -i -e "
      s/^.*WATCHMAN_METRICS_ENABLED=.*/WATCHMAN_METRICS_ENABLED=true/
      s/^.*WATCHMAN_METRICS_INTERVAL=.*/WATCHMAN_METRICS_INTERVAL=$CONF_METRICS_INTERVAL/
    " /etc/openshift/node.conf
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
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh

  WAIT=600
  END=`date -d "$WAIT seconds" +%s`
  echo "OpenShift node: will wait for $WAIT seconds to fetch SSH key."

  while [[ `date +%s` -lt $END ]]; do
    # try to get key hosted on broker machine
    cert=$(wget -q -O- --no-check-certificate "https://${broker_hostname}/rsync_id_rsa.pub?host=${node_hostname}")
    if [ $? -ne 0 ]; then
      sleep 5
    else
      ssh-keygen -lf /dev/stdin <<< $cert
      if [ $? -ne 0 ]; then
        break
      else
        echo $cert >> /root/.ssh/authorized_keys
        echo "OpenShift node: SSH key downloaded from broker successfully."
        chmod 644 /root/.ssh/authorized_keys
        return
      fi
    fi
  done

  echo "OpenShift node: WARNING: could not install rsync_id_rsa.pub key; please do it manually."

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
  : "${CONF_ABORT_ON_UNRECOGNIZED_SETTINGS:=false}"
}

# Parse command-line arguments using parse_args.
parse_cmdline()
{
  parse_args "$@"
}

metapkgs_optional()
{
  [[ ${metapkgs,,} =~ 'optional' ]]
}

metapkgs_recommended()
{
  metapkgs_optional || [[ ${metapkgs,,} =~ 'recommended' ]]
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

is_xpaas()
{ # checks first arg or $node_profile, true if contains "xpaas"
  local profile="${1:-$node_profile}"
  [[ "${profile}" == *xpaas* ]]
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
  #   echo declare -A valid_settings=\( $(grep -o 'CONF_[0-9A-Z_]\+' openshift.ks |sort -u |grep -v -F -e CONF_BAZ -e CONF_FOO |sed -e 's/.*/[&]=/') \)
declare -A valid_settings=( [CONF_ABORT_ON_UNRECOGNIZED_SETTINGS]= [CONF_ACTIONS]= [CONF_ACTIVEMQ_ADMIN_PASSWORD]= [CONF_ACTIVEMQ_AMQ_USER_PASSWORD]= [CONF_ACTIVEMQ_HOSTNAME]= [CONF_ACTIVEMQ_REPLICANTS]= [CONF_AMQ_EXTRA_REPO]= [CONF_BIND_KEY]= [CONF_BIND_KEYALGORITHM]= [CONF_BIND_KEYSIZE]= [CONF_BIND_KEYVALUE]= [CONF_BIND_KRB_KEYTAB]= [CONF_BIND_KRB_PRINCIPAL]= [CONF_BROKER_AUTH_PRIV_KEY]= [CONF_BROKER_AUTH_SALT]= [CONF_BROKER_HOSTNAME]= [CONF_BROKER_IP_ADDR]= [CONF_BROKER_KRB_AUTH_REALMS]= [CONF_BROKER_KRB_SERVICE_NAME]= [CONF_BROKER_SESSION_SECRET]= [CONF_CARTRIDGES]= [CONF_CDN_LAYOUT]= [CONF_CDN_REPO_BASE]= [CONF_CONSOLE_SESSION_SECRET]= [CONF_DATASTORE_HOSTNAME]= [CONF_DATASTORE_REPLICANTS]= [CONF_DEFAULT_DISTRICTS]= [CONF_DEFAULT_GEAR_CAPABILITIES]= [CONF_DEFAULT_GEAR_SIZE]= [CONF_ISOLATE_GEARS]= [CONF_DISTRICT_FIRST_UID]= [CONF_DISTRICT_MAPPINGS]= [CONF_DOMAIN]= [CONF_ENABLE_SNI_PROXY]= [CONF_FORWARD_DNS]= [CONF_FUSE_EXTRA_REPO]= [CONF_HOSTS_DOMAIN]= [CONF_HOSTS_DOMAIN_KEYFILE]= [CONF_IDLE_INTERVAL]= [CONF_INSTALL_COMPONENTS]= [CONF_INSTALL_METHOD]= [CONF_INTERFACE]= [CONF_JBOSSEAP_EXTRA_REPO]= [CONF_JBOSSEWS_EXTRA_REPO]= [CONF_JBOSS_REPO_BASE]= [CONF_KEEP_HOSTNAME]= [CONF_KEEP_NAMESERVERS]= [CONF_MCOLLECTIVE_PASSWORD]= [CONF_MCOLLECTIVE_USER]= [CONF_METAPKGS]= [CONF_METRICS_INTERVAL]= [CONF_MONGODB_ADMIN_PASSWORD]= [CONF_MONGODB_ADMIN_USER]= [CONF_MONGODB_BROKER_PASSWORD]= [CONF_MONGODB_BROKER_USER]= [CONF_MONGODB_KEY]= [CONF_MONGODB_NAME]= [CONF_MONGODB_PASSWORD]= [CONF_MONGODB_REPLSET]= [CONF_NAMED_ENTRIES]= [CONF_NAMED_HOSTNAME]= [CONF_NAMED_IP_ADDR]= [CONF_NO_DATASTORE_AUTH_FOR_LOCALHOST]= [CONF_NODE_APACHE_FRONTEND]= [CONF_NODE_HOSTNAME]= [CONF_NODE_HOST_TYPE]= [CONF_NODE_IP_ADDR]= [CONF_NODE_LOG_CONTEXT]= [CONF_NODE_PROFILE]= [CONF_NODE_PROFILE_NAME]= [CONF_NO_NTP]= [CONF_NO_SCRAMBLE]= [CONF_OPENSHIFT_PASSWORD]= [CONF_OPENSHIFT_PASSWORD1]= [CONF_OPENSHIFT_USER]= [CONF_OPENSHIFT_USER1]= [CONF_OPTIONAL_REPO]= [CONF_OSE_ERRATA_BASE]= [CONF_OSE_EXTRA_REPO_BASE]= [CONF_OSE_REPO_BASE]= [CONF_PORTS_PER_GEAR]= [CONF_PROFILE_NAME]= [CONF_REPOS_BASE]= [CONF_RHEL_EXTRA_REPO]= [CONF_RHEL_OPTIONAL_REPO]= [CONF_RHEL_REPO]= [CONF_RHN_PASS]= [CONF_RHN_REG_ACTKEY]= [CONF_RHN_REG_NAME]= [CONF_RHN_REG_OPTS]= [CONF_RHN_REG_PASS]= [CONF_RHN_USER]= [CONF_RHSCL_EXTRA_REPO]= [CONF_RHSCL_REPO_BASE]= [CONF_ROUTING_PLUGIN]= [CONF_ROUTING_PLUGIN_PASS]= [CONF_ROUTING_PLUGIN_USER]= [CONF_SM_REG_NAME]= [CONF_SM_REG_PASS]= [CONF_SM_REG_POOL]= [CONF_SNI_FIRST_PORT]= [CONF_SNI_PROXY_PORTS]= [CONF_SYSLOG]= [CONF_VALID_GEAR_SIZES]= [CONF_YUM_EXCLUDE_PKGS]= )

  for setting in "${!CONF_@}"
  do
    if ! [[ ${valid_settings[$setting]+1} ]]
    then
      if is_true "$abort_on_unrecognized_settings"
      then
        abort_install "Unrecognized setting: $setting"
      else
        echo "WARNING: Unrecognized setting: $setting"
      fi
    else
      # The setting is recognized, so check whether a non-empty value is given.
      [[ ${!setting} ]] || abort_install "Setting is assigned an empty value: $setting"
    fi
  done

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
    case "$component" in
      (broker|node|named|activemq|datastore) ;;
      (*) abort_install "Unrecognized component: $component" ;;
    esac
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

  # The list of packages to install.
  cartridges="${CONF_CARTRIDGES:-standard}"

  # There a no defaults for these. Customers should be using
  # subscriptions via RHN. Internally we use private systems.
  rhel_repo="${CONF_RHEL_REPO%/}"
  rhel_extra_repo="${CONF_RHEL_EXTRA_REPO%/}"
  jboss_repo_base="${CONF_JBOSS_REPO_BASE%/}"
  jbosseap_extra_repo="${CONF_JBOSSEAP_EXTRA_REPO%/}"
  jbossews_extra_repo="${CONF_JBOSSEWS_EXTRA_REPO%/}"
  fuse_extra_repo="${CONF_FUSE_EXTRA_REPO%/}"
  amq_extra_repo="${CONF_AMQ_EXTRA_REPO%/}"
  rhscl_repo_base="${CONF_RHSCL_REPO_BASE%/}"
  rhscl_extra_repo="${CONF_RHSCL_EXTRA_REPO%/}"
  rhel_optional_repo="${CONF_RHEL_OPTIONAL_REPO%/}"
  # Where to find the OpenShift repositories; just the base part before
  # splitting out into Infrastructure/Node/etc.
  ose_repo_base="${CONF_OSE_REPO_BASE:-$CONF_REPOS_BASE}"
  ose_repo_base="${ose_repo_base%/}"

  # Use CDN layout as the default for all yum repos if this is set.
  cdn_repo_base="${CONF_CDN_REPO_BASE%/}"
  if [ "x$cdn_repo_base" != "x" ]; then
    rhel_repo="${rhel_repo:-$cdn_repo_base/os}"
    jboss_repo_base="${jboss_repo_base:-$cdn_repo_base}"
    rhscl_repo_base="${rhscl_repo_base:-$cdn_repo_base}"
    rhel_optional_repo="${rhel_optional_repo:-$cdn_repo_base/optional/os}"
    ose_repo_base="${ose_repo_base:-$cdn_repo_base}"
    if [ "${cdn_repo_base}" == "${ose_repo_base}" ]; then # same repo layout
      CONF_CDN_LAYOUT=1  # use the CDN layout for OpenShift yum repos
    fi
  elif [ "${rhel_repo}" == "${ose_repo_base}/os" ]; then # OSE same repo base as RHEL?
    CONF_CDN_LAYOUT=1  # use the CDN layout for OpenShift yum repos
  fi
  ose_extra_repo_base="${CONF_OSE_EXTRA_REPO_BASE%/}"
  rhscl_repo_base="${rhscl_repo_base:-${rhel_repo%/os}}"
  # no need to waste time checking both subscription plugins if using one
  disable_plugin=""
  [[ "$CONF_INSTALL_METHOD" == "rhsm" ]] && disable_plugin='--disableplugin=rhnplugin'
  [[ "$CONF_INSTALL_METHOD" == "rhn" ]] && disable_plugin='--disableplugin=subscription-manager'
  # could do the same for "yum" method but it's more likely to surprise someone
  #[[ "$CONF_INSTALL_METHOD" == "yum" ]] && disable_plugin='--disableplugin=subscription-manager --disableplugin=rhnplugin'

  # remap subscription parameters used previously
  CONF_RHN_USER="${CONF_RHN_USER:-${CONF_SM_REG_NAME:-$CONF_RHN_REG_NAME}}"
  set +x # don't log password
  CONF_RHN_PASS="${CONF_RHN_PASS:-${CONF_SM_REG_PASS:-$CONF_RHN_REG_PASS}}"
  set -x

  # The domain name for the OpenShift Enterprise installation.
  domain="${CONF_DOMAIN:-example.com}"
  hosts_domain="${CONF_HOSTS_DOMAIN:-$domain}"
  hosts_domain_keyfile="${CONF_HOSTS_DOMAIN_KEYFILE:-/var/named/${hosts_domain}.key}"

  # hostnames to use for the components (could all resolve to same host)
  broker_hostname=$(ensure_domain "${CONF_BROKER_HOSTNAME:-broker}" "$hosts_domain")
  node_hostname=$(ensure_domain "${CONF_NODE_HOSTNAME:-node}" "$hosts_domain")
  named_hostname=$(ensure_domain "${CONF_NAMED_HOSTNAME:-ns1}" "$hosts_domain")
  activemq_hostname=$(ensure_domain "${CONF_ACTIVEMQ_HOSTNAME:-activemq}" "$hosts_domain")
  datastore_hostname=$(ensure_domain "${CONF_DATASTORE_HOSTNAME:-datastore}" "$hosts_domain")

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

  # how to label the system when subscribing
  profile_name="${CONF_PROFILE_NAME:-OpenShift-${hostname}-${cur_ip_addr}-${CONF_RHN_USER}}"

  node_apache_frontend="${CONF_NODE_APACHE_FRONTEND:-vhost}"

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

  # Main interface to configure
  interface="${CONF_INTERFACE:-eth0}"

  # Set $bind_krb_keytab and $bind_krb_principal to the values of
  # $CONF_BIND_KRB_KEYTAB and $CONF_BIND_KRB_PRINCIPAL if these values
  # are both non-empty, or set $bind_key to the value of $CONF_BIND_KEY
  # if the latter is non-empty.
  if [ "x$CONF_BIND_KRB_KEYTAB" != x ] && [ "x$CONF_BIND_KRB_PRINCIPAL" != x ] ; then
  bind_krb_keytab="$CONF_BIND_KRB_KEYTAB"
  bind_krb_principal="$CONF_BIND_KRB_PRINCIPAL"
  else
  bind_key="$CONF_BIND_KEY"
  bind_keyalgorithm="${CONF_BIND_KEYALGORITHM:-HMAC-SHA256}"
  bind_keysize="${CONF_BIND_KEYSIZE:-256}"
  fi

  for s in valid_gear_sizes default_gear_capabilities default_gear_size; do
    eval "isset_${s}() { false; }"
  done

  # Set $valid_gear_sizes to $CONF_VALID_GEAR_SIZES
  [ -n "$CONF_VALID_GEAR_SIZES" ] && isset_valid_gear_sizes() { :; }
  broker && valid_gear_sizes="${CONF_VALID_GEAR_SIZES:-small}"

  # Set $default_gear_capabilities to $CONF_DEFAULT_GEAR_CAPABILITIES
  [ -n "$CONF_DEFAULT_GEAR_CAPABILITIES" ] && isset_default_gear_capabilities() { :; }
  broker && default_gear_capabilities="${CONF_DEFAULT_GEAR_CAPABILITIES:-${valid_gear_sizes}}"

  # Set $default_gear_size to $CONF_DEFAULT_GEAR_SIZE
  [ -n "$CONF_DEFAULT_GEAR_SIZE" ] && isset_default_gear_size() { :; }
  broker && default_gear_size="${CONF_DEFAULT_GEAR_SIZE:-${valid_gear_sizes%%,*}}"

  # Set $node_profile to $CONF_NODE_PROFILE
  node && node_profile="${CONF_NODE_PROFILE:-small}"
  node && node_profile_name="${CONF_NODE_PROFILE_NAME:-$node_profile}"
  node && node_host_type="${CONF_NODE_HOST_TYPE:-m3.xlarge}"
  # determine node port and UID settings
  local def_ports=5; is_xpaas && def_ports=15
  ports_per_gear="${CONF_PORTS_PER_GEAR:-$def_ports}"
  district_first_uid="${CONF_DISTRICT_FIRST_UID:-1000}"
  let "district_uid_pool=30000/$ports_per_gear"
  let "district_last_uid=$district_first_uid+$district_uid_pool-1"
  isolate_gears="${CONF_ISOLATE_GEARS:-true}"
  # determine node sni proxy settings
  local def_enable="false"; is_xpaas && def_enable="true"
  enable_sni_proxy="${CONF_ENABLE_SNI_PROXY:-$def_enable}"
  sni_first_port="${CONF_SNI_FIRST_PORT:-2303}"
  def_ports=5; is_xpaas && def_ports=10
  sni_proxy_ports="${CONF_SNI_PROXY_PORTS:-$def_ports}"
  let "sni_last_port=$sni_first_port+$sni_proxy_ports-1"

  # Set $default_districts to $CONF_DEFAULT_DISTRICTS
  broker && default_districts=${CONF_DEFAULT_DISTRICTS:-true}

  # Set $district_mappings to $CONF_DISTRICT_MAPPINGS
  broker && district_mappings=$CONF_DISTRICT_MAPPINGS

  # Generate a random salt for the broker authentication.
  randomized=$(openssl rand -base64 20)
  broker && broker_auth_salt="${CONF_BROKER_AUTH_SALT:-${randomized}}"

  # Generate a random session secret for broker sessions.
  randomized=$(openssl rand -hex 64)
  broker && broker_session_secret="${CONF_BROKER_SESSION_SECRET:-${randomized}}"

  # Generate a random session secret for console sessions.
  randomized=$(openssl rand -hex 64)
  broker && console_session_secret="${CONF_CONSOLE_SESSION_SECRET:-${randomized}}"

  # Generate a new 2048 bit RSA keypair for broker authentication if
  # CONF_BROKER_AUTH_PRIV_KEY not set
  broker && broker_auth_priv_key="${CONF_BROKER_AUTH_PRIV_KEY:-$(openssl genrsa 2048)}"

  # If no list of replicants is provided, assume there is only one datastore host.
  datastore_replicants="${CONF_DATASTORE_REPLICANTS:-$datastore_hostname:27017}"
  # For each replicant that does not have an explicit port number
  # specified, append :27017 to its host name.
  datastore_replicants="$( for repl in ${datastore_replicants//,/ }; do
                             [[ "$repl" =~ : ]] || repl=$repl:27017
                             printf ",%s" "${repl}"
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
  activemq && assign_pass activemq_amq_user_password "password" CONF_ACTIVEMQ_AMQ_USER_PASSWORD

  #   This is the user and password shared between broker and node for
  #   communicating over the mcollective topic channels in ActiveMQ.
  #   Must be the same on all broker and node hosts.
  (broker || node || activemq) && mcollective_user="${CONF_MCOLLECTIVE_USER:-mcollective}"
  (broker || node || activemq) && assign_pass mcollective_password "marionette" CONF_MCOLLECTIVE_PASSWORD

  #   These are the username and password of the administrative user
  #   that will be created in the MongoDB datastore. These credentials
  #   are not used by in this script or by OpenShift, but an
  #   administrative user must be added to MongoDB in order for it to
  #   enforce authentication.
  datastore && mongodb_admin_user="${CONF_MONGODB_ADMIN_USER:-admin}"
  datastore && tmpvar=${CONF_MONGODB_ADMIN_PASSWORD:-${CONF_MONGODB_PASSWORD}}
  datastore &&  assign_pass mongodb_admin_password "mongopass" tmpvar

  #   These are the username and password of the normal user that will
  #   be created for the broker to connect to the MongoDB datastore. The
  #   broker application's MongoDB plugin is also configured with these
  #   values.
  (datastore || broker) && mongodb_broker_user="${CONF_MONGODB_BROKER_USER:-openshift}"
  (datastore || broker) && tmpvar=${CONF_MONGODB_BROKER_PASSWORD:-${CONF_MONGODB_PASSWORD}}
  (datastore || broker) && assign_pass mongodb_broker_password "mongopass" tmpvar

  #   In replicated setup, this is the key that slaves will use to
  #   authenticate with the master.
  datastore && assign_pass mongodb_key "OSEnterprise" CONF_MONGODB_KEY

  #   In replicated setup, this is the name of the replica set.
  mongodb_replset="${CONF_MONGODB_REPLSET:-ose}"

  #   This is the name of the database in MongoDB in which the broker
  #   will store data.
  mongodb_name="${CONF_MONGODB_NAME:-openshift_broker}"

  #   This user and password are entered in the /etc/openshift/htpasswd
  #   file as a demo/test user. You will likely want to remove it after
  #   installation (or just use a different auth method).
  broker && openshift_user1="${CONF_OPENSHIFT_USER1:-demo}"
  broker && assign_pass openshift_password1 "changeme" CONF_OPENSHIFT_PASSWORD1

  # auth info for the topic from the sample routing SPI plugin
  routing_plugin_user="${CONF_ROUTING_PLUGIN_USER:-routinginfo}"
  assign_pass routing_plugin_pass "routinginfopassword" CONF_ROUTING_PLUGIN_PASS

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
  [ "$environment" = ks ] && configure_console_msg
}

validate_preflight()
{
  echo "OpenShift: Begin preflight validation."
  preflight_failure=

  # Test that this isn't RHEL < 6 or Fedora
  if ! grep -q "Enterprise.* 6" /etc/redhat-release; then
    echo "OpenShift: This process needs to begin with Enterprise Linux 6 installed."
    preflight_failure=1
  fi

  # Test that SELinux is at least present and not Disabled
  if ! command -v getenforce || ! [[ $(getenforce) =~ Enforcing|Permissive ]] ; then
    echo "OpenShift: SELinux needs to be installed and enabled."
    preflight_failure=1
  fi

  # Test that rpm/yum exists and isn't totally broken
  if ! command -v rpm || ! command -v yum; then
    echo "OpenShift: rpm and yum must be installed."
    preflight_failure=1
  fi
  if ! rpm -q rpm yum; then
    echo "OpenShift: rpm command failed; there may be a problem with the RPM DB."
    preflight_failure=1
  fi

  # test that subscription parameters are available if needed
  if [[ "$CONF_INSTALL_METHOD" = rhn ]]; then
    # Check whether we are already registered with RHN and already have
    # ose-2.2 channels added.  If we are not, we will need RHN
    # credentials so that we can register and add channels ourselves.
    #
    # Note: With RHN, we need credentials both for registration and
    # adding channels.
    if ! [[ -f /etc/sysconfig/rhn/systemid ]] || ! rhn-channel -l | grep -q '^rhel-x86_64-server-6-ose-2.2-\(node\|infrastructure\)'
    then
      set +x # don't log password
      if [ ! "$CONF_RHN_USER" -o ! "$CONF_RHN_PASS" ]; then
        echo "OpenShift: Install method rhn requires an RHN user and password."
        preflight_failure=1
      fi
      set -x
    fi
  fi

  if [[ "$CONF_INSTALL_METHOD" = rhsm ]]; then
    # Check whether we are already registered with RHSM.  If we are not,
    # we will need credentials so that we can register ourselves.
    #
    # Note: With RHSM, we need credentials for registration but not for
    # adding channels.
    if ! subscription-manager identity | grep -q 'identity is:'; then
      set +x # don't log password
      if [ ! "$CONF_RHN_USER" -o ! "$CONF_RHN_PASS" ]; then
        echo "OpenShift: Install method rhsm requires an RHN user and password."
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
    if [[ ! "$CONF_SM_REG_POOL" ]] &&
        ( [[ "$CONF_RHN_USER" && "$CONF_RHN_PASS" ]] ||
          ! subscription-manager repos | tac | grep -q '\<rhel-6-server-ose-2.2-\(infra\|node\)-rpms$' ); then
      echo "OpenShift: Install method rhsm requires a poolid."
      preflight_failure=1
    fi
  fi

  if [ "$CONF_INSTALL_METHOD" = yum -a ! "$ose_repo_base" ]; then
    echo "OpenShift: Install method yum requires providing URLs for at least OpenShift repos."
    preflight_failure=1
  fi

  # Test that known problematic RPMs aren't present
  # ... ?

  [ "$preflight_failure" ] && abort_install
  echo "OpenShift: Completed preflight validation."
}

install_rpms()
{
  echo "OpenShift: Begin installing RPMs."
  # we often rely on latest selinux policy and other updates
  echo "OpenShift: yum update"
  yum $disable_plugin clean all

  COUNT=0
  while true; do
    yum $disable_plugin update -y
    if [ $? -eq 0 ]; then
      break
    elif [ $COUNT -gt 3 ]; then
      abort_install
    fi
    let COUNT+=1
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
  echo "OpenShift: Completed installing RPMs."
}

configure_host()
{
  echo "OpenShift: Begin configuring host."
  is_false "$CONF_NO_NTP" && synchronize_clock
  # Note: configure_named must run before configure_controller if we are
  # installing both named and broker on the same host.
  named && configure_named
  configure_network
  is_false "$CONF_KEEP_NAMESERVERS" && configure_dns_resolution
  is_false "$CONF_KEEP_HOSTNAME" && configure_hostname

  # minimize grub timeout on startup
  sed -i -e 's/^timeout=.*/timeout=1/' /etc/grub.conf;

  # Remove VirtualHost from the default httpd ssl.conf to prevent a warning
  sed -i '/VirtualHost/,/VirtualHost/ d' /etc/httpd/conf.d/ssl.conf

  # Reset the firewall to disable lokkit and initialise iptables configuration.
  configure_firewall

  # all hosts should enable ssh access
  firewall_allow[ssh]=tcp:22
  configure_firewall_add_rules
  echo "OpenShift: Completed configuring host."
}

configure_firewall()
{
  # Disable lokkit.
  conf='/etc/sysconfig/system-config-firewall'
  [[ "$(< "$conf")" != --disabled ]] &&
    mv "$conf" "${conf}.bak"
  echo '--disabled' > "$conf"

  # Configure iptables.
cat > /etc/sysconfig/iptables <<'EOF'
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
  rules=""
  for svc in ${!firewall_allow[@]}
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
  sed -i -e $'/-A INPUT -j REJECT/i \\\n'"${rules:3}" /etc/sysconfig/iptables
}

configure_gear_isolation_firewall()
{
  is_true "$isolate_gears" && oo-gear-firewall -i conf -b "$district_first_uid" -e "$district_last_uid"
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

  node && configure_port_proxy
  node && configure_gears
  node && configure_node
  node && configure_selinux_policy_on_node # must run after configure_node
  node && configure_wildcard_ssl_cert_on_node
  node && update_openshift_facts_on_node

  node && broker && fix_broker_routing
  node && install_rsync_pub_key

  configure_firewall_add_rules
  node && configure_gear_isolation_firewall

  sysctl -p
  restorecon -rv /etc/openshift

  PASSWORDS_TO_DISPLAY=true
  RESTART_NEEDED=true
  echo "OpenShift: Completed configuring OpenShift."
}

restart_services()
{
  echo "OpenShift: Begin restarting services."

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

  # ensure openshift facts are updated
  node && /etc/cron.minutely/openshift-facts

  echo "OpenShift: Completed restarting services."
}

run_diagnostics()
{
  echo "OpenShift: Begin running oo-diagnostics."
  date +%Y-%m-%d-%H:%M:%S
  # prepending the output of oo-diagnostics breaks the ansi color coding
  # remove all ansi escape sequences from oo-diagnostics output
  oo-diagnostics |& sed -u -e 's/\x1B\[[0-9;]*[JKmsu]//g' -e 's/^/OpenShift: oo-diagnostics output - /g'
  date +%Y-%m-%d-%H:%M:%S
  echo "OpenShift: Completed running oo-diagnostics."
}

reboot_after()
{
  echo "OpenShift: Rebooting after install."
  reboot
}

configure_districts()
{
  echo "OpenShift: Configuring districts."
  date +%Y-%m-%d-%H:%M:%S

  local restart=$RESTART_NEEDED
  if is_true "$default_districts"; then
    for p in ${valid_gear_sizes//,/ }; do
      is_xpaas "$p" && configure_messaging_plugin 15  # xpaas profile requires more ports
      oo-admin-ctl-district -p $p -n default-${p} -c add-node --available |& sed -e 's/^\(Error\)/OpenShift: oo-admin-ctl-district - \1/g'
      is_xpaas "$p" && configure_messaging_plugin  # back to default
    done
  else
    for mapping in ${district_mappings//;/ }; do
      district="${mapping%%:*}"
      nodes="${mapping#*:}"
      firstnode=${nodes//,*/}
      # query the node for the node profile via mcollective
      profile=""
      for i in {1..10}; do
        profile=$(oo-ruby -e "require 'mcollective'; include MCollective::RPC; mc=rpcclient('rpcutil'); mc.progress=false; result=mc.custom_request('get_fact', {:fact => 'node_profile'}, ['${firstnode}'], {'identity' => '${firstnode}'}); if not result.empty?;  value=result.first.results[:data][:value]; if not value.nil? and not value.empty?; puts value; exit 0; end; end; exit 1" 2>/dev/null)
        if [ $? -eq 0 ]; then
          break;
        fi
        sleep 10
      done
      if [ "x$profile" != "x" ]; then
        echo "OpenShift: Adding nodes: $nodes with profile: $profile to district: $district."
        is_xpaas "$profile" && configure_messaging_plugin 15  # xpaas profile requires more ports
        oo-admin-ctl-district -p $profile -n $district -c add-node -i $nodes |& sed -e 's/^\(Error\)/OpenShift: oo-admin-ctl-district - \1/g'
        is_xpaas "$profile" && configure_messaging_plugin  # back to default
      else
        echo "OpenShift: Could not determine gear profile for nodes: ${nodes}, cannot add to district $district"
      fi
    done
  fi
  # configuring districts should not normally require a service restart
  RESTART_NEEDED=$restart

  date +%Y-%m-%d-%H:%M:%S
  echo "OpenShift: Completed configuring districts."
}

post_deploy()
{
  echo "OpenShift: Begin post deployment steps."

  if broker; then
    if isset_valid_gear_sizes || isset_default_gear_capabilities || isset_default_gear_size; then
      update_controller_gear_size_configs
      RESTART_NEEDED=true
    fi

    $RESTART_NEEDED && restart_services && RESTART_COMPLETED=true

    # import cartridges
    oo-admin-ctl-cartridge -c import-node --activate --obsolete

    configure_districts
  fi

  echo "OpenShift: Completed post deployment steps."
}

do_all_actions()
{ # Avoid adding or removing these top-level actions.
  # oo-install invokes these individually in separate phases.
  # So, they should not assume the others ran previously in
  # the same invocation.
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
environment=amz
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

# Initialize associative array to which firewall rules can be added (see
# configure_firewall_add_rules).  This must be declared here for scoping.
declare -A firewall_allow

set_defaults

date +%Y-%m-%d-%H:%M:%S
for action in ${actions//,/ }
do
  [ "$(type -t "$action")" = function ] || abort_install "Invalid action: ${action}"
  "$action"
done
date +%Y-%m-%d-%H:%M:%S

# In the case of a kickstart, some services will not be able to start, and the
# host will automatically reboot anyway after the kickstart script completes.
[[ "$environment" = ks ]] && RESTART_NEEDED=false

$RESTART_NEEDED && ! $RESTART_COMPLETED && restart_services

$PASSWORDS_TO_DISPLAY && display_passwords


chmod 600 /root/.ssh/named_rsa

# Keeps the broker from getting SSH warnings when running the client
configure_permissive_ssh()
{
cat <<EOF >> /etc/ssh/ssh_config

Host *.cloudydemo.com
   CheckHostIP no
   StrictHostKeyChecking no
EOF
}

# Copy the DNS key from the named host to the broker
set_dns_key()
{
  SSH_CMD="ssh -n -o TCPKeepAlive=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PasswordAuthentication=no -i /root/.ssh/named_rsa"
  KEY=$(${SSH_CMD} ${named_hostname} "grep Key: /var/named/K${domain}*.private | cut -d ' ' -f 2")
}

# Fix the node configuration to just use the hostname
# Amazon machines have fully qualified hostnames
configure_node_amz()
{
  sed -i -e "s/^PUBLIC_HOSTNAME=.*$/PUBLIC_HOSTNAME=${hostname}/" /etc/openshift/node.conf
}

# Configures named with the correct public IP
configure_named_amz()
{
  # Get the public ip address
  IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)

  # Replace the bind configuration with the public ip address
  sed -i -e "s/A 127.0.0.1/A ${IP}/" /var/named/dynamic/${domain}.db
}

# Configures the LIBRA_SERVER variable for convenience
configure_libra_server()
{
  echo "export LIBRA_SERVER='${broker_hostname}'" >> /root/.bashrc
}

# This fixes the BIND configuration on the named server by
# setting up the public IP address instead of 127.0.0.1
named && configure_named_amz

# This will keep you from getting SSH warnings if you
# are running the client on the broker
broker && configure_permissive_ssh

# This sets up the LIBRA_SERVER on the broker machine
# for convenience of running 'rhc' on it
broker && configure_libra_server

# Re-configure the node hostname for Amazon hosts
node && configure_node_amz

if [ "x$2" != "x" ]
then
  # Important - the callback is only working
  # if the file data is sent up.  Probably related
  # to the newlines after the initial brace.
  cat <<EOF > /tmp/success_data
{
  "Status" : "SUCCESS",
  "Reason" : "Configuration Complete",
  "UniqueId" : "$1",
  "Data" : "Component has completed configuration."
}
EOF

  # This calls the verification URL for the CloudFormation
  # wait condition.  Again, it's really important to use
  # the file format or you will never unblock the wait state.
  echo "Calling wait URL..."
  curl -T /tmp/success_data $2
  echo "Done"
fi

# The kickstart requires the machines to be restarted
# in order to properly start the right services, firewalls,
# etc.  The restart does not re-IP the Amazon machines.
echo "Restarting VM"
reboot
