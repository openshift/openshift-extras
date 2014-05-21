# do the things that are specific to the VM
setup_vm()
{
  setup_vm_host
  setup_vm_user
  clean_vm
}

# The RHEL + OSE VM requires the setup of a default user.
setup_vm_host()
{
  # fabricated function to lay down files from the parts/ dir
  create_vm_files

  # service to work around VM networking issue
  chmod +x /etc/init.d/openshift-await-eth0
  chkconfig openshift-await-eth0 on
  # service to regenerate external-facing keys/secrets at first boot
  chmod +x /etc/init.d/openshift-vmfirstboot
  chkconfig openshift-vmfirstboot on

  # create a hook that updates the DNS record when our IP changes
  local name=${broker_hostname%$hosts_domain}
  cat <<HOOK > /etc/dhcp/dhclient-eth0-up-hooks
    if [[ "\$new_ip_address"x != x ]]; then
      /usr/sbin/rndc freeze ${hosts_domain}
      sed -i -e "s/^vm\s\+\(IN \)\?A\s\+.*/vm A \$new_ip_address/" /var/named/dynamic/${hosts_domain}.db
      /usr/sbin/rndc thaw ${hosts_domain}
      sed -i -e "s/^PUBLIC_IP=.*/PUBLIC_IP=\$new_ip_address/" /etc/openshift/node.conf
    fi
HOOK
  chmod +x /etc/dhcp/dhclient-eth0-up-hooks

  # modify selinux policy to allow above script to change named conf from dhcp client
  pushd /tmp
    make -f /usr/share/selinux/devel/Makefile
    semodule -i dhcp-update-named.pp
    rm dhcp-update-named.*
  popd

  # Set up PAM so that console users can restart services without polyinstantiation
  #for file in /etc/pam.d/{newrole,runuser,sshd,su,sudo,system-auth}; do
  for file in /etc/pam.d/{newrole,sshd,su,sudo,system-auth}; do
    cat <<PAMAUTH >> $file
session    [default=1 success=ignore]  pam_succeed_if.so quiet user in root:apache:mongodb:activemq
session    required                    pam_namespace.so  unmnt_only
PAMAUTH
  done
  for file in /etc/security/namespace.d/*.conf; do
    sed -i -e 's/root,adm//' $file
  done

  # Set the runlevel to graphical
  /bin/sed -i -e 's/id:.:initdefault:/id:5:initdefault:/' /etc/inittab

  # no need for root to login with a password.
  /usr/bin/passwd -l root

  # prevent rhc/JBDS warnings about host's httpd certificate
  cat <<INSECURE >> /etc/openshift/express.conf
# Ignore certificate errors. VM is installed with self-signed certificate.
insecure=true
INSECURE

}

setup_vm_user()
{
  # Create the 'openshift' user
  /usr/sbin/useradd openshift
  /bin/echo 'openshift:openshift' | /usr/sbin/chpasswd -c SHA512

  # fabricated function to lay down files from the parts/ dir
  create_vmuser_files

  # Set up the 'openshift' user for auto-login
  /usr/sbin/groupadd nopasswdlogin
  /usr/sbin/usermod -G openshift,nopasswdlogin openshift
  # TODO: automatically log the user in
  /bin/sed -i -e '
# Trying to enable autologin for gdm => openshift fails, either
# by simply not logging in, or by bringing up a black screen. Symptoms
# in the latter case are similar to https://bugzilla.redhat.com/show_bug.cgi?id=629328
# Perhaps is related to pam issues.
#/^\[daemon\]/a \
#AutomaticLogin=openshift \
#AutomaticLoginEnable=true
#
# We do not want gear users to show up in the greeter
/^\[greeter\]/a \
IncludeAll=false \
Include=openshift
' /etc/gdm/custom.conf
  /bin/sed -i -e '1i \
auth sufficient pam_succeed_if.so user ingroup nopasswdlogin' /etc/pam.d/gdm-password
  # add the user to sudo
  echo "openshift ALL=(ALL)  NOPASSWD: ALL" > /etc/sudoers.d/openshift
  # Disable locking the user desktop for inactivity
  su - openshift -c 'gconftool-2 -s /apps/gnome-screensaver/idle_activation_enabled --type=bool false'
  # TODO: get rid of email launcher, add terminal launcher
  # TODO: add JBoss Dev Suite launcher

  # accept the server certificate in Firefox
  mkdir -p /home/openshift/.mozilla/firefox
  pushd /home/openshift/.mozilla/firefox
    local ffprof=`mktemp -d XXXXXXXX.default`
    cat <<PROFILES > profiles.ini
[General]
StartWithLastProfile=1

[Profile0]
Name=default
IsRelative=1
Path=$ffprof
PROFILES
    certName='OpenShift Enterprise VM'
    certFile='/etc/pki/tls/certs/localhost.crt'
    certutil -A -n "$certName" -t "TCu,Cuw,Tuw" -i "$certFile" -d "$ffprof"
  popd

  mkdir -p /home/openshift/.ssh
  cat <<SSHCONF > /home/openshift/.ssh/config
# prevent ssh warnings about host keys for new apps
Host *.${hosts_domain}
  StrictHostKeyChecking no
  UserKnownHostsFile ~/.ssh/vm_known_hosts
  # disable unused auth methods
  PasswordAuthentication no
  GSSAPIAuthentication no
SSHCONF
  chmod -R go-r /home/openshift/.ssh

  # TODO: enable openshift user capabilities by default: allow HA apps, private ssl certs, teams, ...

  # install oo-install and default config
  wget $OO_INSTALL_URL -O /home/openshift/oo-install.zip --no-check-certificate -nv
  su - openshift -c 'unzip oo-install.zip -d oo-install'
  rm /home/openshift/oo-install.zip

  # fix ownership
  chown -R openshift:openshift /home/openshift

  # install JBoss Developer Suite
  wget $JBDS_URL -O /home/openshift/jbds.jar --no-check-certificate -nv
  # https://access.redhat.com/site/solutions/44667 for auto install
  su - openshift -c 'java -jar jbds.jar jbdevstudio/jbds-install.xml' && rm /home/openshift/jbds.jar
}

clean_vm()
{
  # clean vm of anything it should not keep
  if [ "$DEBUG_VM"x = "x" ]; then
    # items to skip when debugging:
    rm -f /etc/yum.repos.d/* /tmp/ks*
    yum clean all
    # anaconda does *not* like when its log files disappear. just truncate them.
    for file in /root/anaconda* /var/log/anaconda*; do echo > $file; done
    #virt-sysprep --enable abrt-data,bash-history,dhcp-client-state,machine-id,mail-spool,pacct-log,smolt-uuid,ssh-hostkeys,sssd-db-log,udev-persistent-net,utmp,net-hwaddr
  fi
  # clean even when debugging
  rm /etc/udev/rules.d/70-persistent-net.rules  # keep specific NIC from being recorded
  sed -i -e '/^HWADDR/ d' /etc/sysconfig/network-scripts/ifcfg-eth0 # keep HWADDR from being recorded
}

