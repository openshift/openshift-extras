#!/usr/bin/python -tt

import sys
import repo_db
from check_sources import OpenShiftCheckSources
from itertools import chain
import logging

OSE_PRIORITY = 10
RHEL_PRIORITY = 20
JBOSS_PRIORITY = 30
OTHER_PRIORITY = 40

UNKNOWN, RHSM, RHN = ('unknown', 'rhsm', 'rhn')

def flatten(llist):
    """Cheap and easy flatten - only works up to two degrees of nesting.

    Works on this: [1, 2, [3], [4, 5]] but won't handle [1, 2, [3], [4, [5]]]
    """
    try:
        return [item for sublist in llist for item in sublist]
    except TypeError:
        newlist = flatten(filter(lambda xx: hasattr(xx, '__iter__'), llist))
        return newlist + filter(lambda xx: not hasattr(xx, '__iter__'), llist)

class OpenShiftAdminCheckSources:
    valid_roles = ['node', 'broker', 'client', 'node-eap']
    valid_oo_versions = ['1.2', '2.0']

    pri_header = False
    pri_resolve_header = False

    def __init__(self, opts, opt_parser):
        self.opts = opts
        self.opt_parser = opt_parser
        self._setup_logger()
        self.oscs = OpenShiftCheckSources()
        self.report = {}
        self.subscription = UNKNOWN

    def _setup_logger(self):
        self.opts.loglevel = logging.INFO
        self.logger = logging.getLogger() # TODO: log to file if specified, with requested severity
        self.logger.setLevel(self.opts.loglevel)
        ch = logging.StreamHandler(sys.stdout)
        ch.setLevel(self.opts.loglevel)
        ch.setFormatter(logging.Formatter("%(message)s"))
        self.logger.addHandler(ch)
        # if self.opts.logfile:
        #     self.logger.addHandler(logfilehandler)
        
    def required_repos(self):
        return flatten([repo_db.find_repos(subscription = self.subscription,
                                           role = rr,
                                           product_version = self.opts.oo_version)
                        for rr in self.opts.role])

    def required_repoids(self):
        return flatten([repo_db.find_repoids(subscription = self.subscription,
                                             role = rr,
                                             product_version = self.opts.oo_version)
                        for rr in self.opts.role])

    def enabled_blessed_repos(self):
        enabled = self.oscs.enabled_repoids()
        return [repo for repo in repo_db.find_repos_by_repoid(enabled)
                if repo.subscription == self.subscription
                and repo.product_version == self.opts.oo_version]

    def blessed_repoids(self, **kwargs):
        return [repo.repoid for repo in self.blessed_repos(**kwargs)]

    def blessed_repos(self, enabled = False, required = False, product = None):
        kwargs = {'subscription': self.subscription, 'product_version': self.opts.oo_version}
        if product:
            kwargs['product'] = product
        req_repos = self.required_repos()
        if enabled:
            if required:
                return [repo for repo in self.required_repos() 
                        if repo.repoid in self.oscs.enabled_repoids()
                        and (not product or repo.product == product)]
            return [repo for repo in repo_db.find_repoids(**kwargs)
                    if repo.repoid in self.oscs.enabled_repoids()]
        if required:
            return [repo for repo in self.required_repos()
                    if not product or repo.product == product]
        return repo_db.find_repos(**kwargs)
        
    def _sub_ver(self, subscription, version = None):
        if subscription == 'rhsm':
            self.subscription = RHSM
        if subscription == 'rhn':
            self.subscription = RHN
        if self.opts.oo_version:
            return True
        if version:
            self.logger.info('Detected installed OpenShift Enterprise version %s'%version)
            self.opts.oo_version = version
            return True
        return False

    def guess_ose_version(self):
        matches = repo_db.find_repos_by_repoid(self.oscs.all_repoids())
        rhsm_ose_2_0 = [xx for xx in matches
                        if xx in repo_db.find_repos(subscription = 'rhsm', product_version = '2.0', product = 'ose')]
        rhn_ose_2_0 = [xx for xx in matches
                       if xx in repo_db.find_repos(subscription = 'rhn', product_version = '2.0', product = 'ose')]
        rhsm_ose_1_2 = [xx for xx in matches
                        if xx in repo_db.find_repos(subscription = 'rhsm', product_version = '1.2', product = 'ose')]
        rhn_ose_1_2 = [xx for xx in matches
                       if xx in repo_db.find_repos(subscription = 'rhn', product_version = '1.2', product = 'ose')]
        rhsm_2_0_avail = [xx for xx in rhsm_ose_2_0 if xx.repoid in self.oscs.enabled_repoids()]
        rhn_2_0_avail = [xx for xx in rhn_ose_2_0 if xx.repoid in self.oscs.enabled_repoids()]
        rhsm_1_2_avail = [xx for xx in rhsm_ose_1_2 if xx.repoid in self.oscs.enabled_repoids()]
        rhn_1_2_avail = [xx for xx in rhn_ose_1_2 if xx.repoid in self.oscs.enabled_repoids()]
        rhsm_2_0_pkgs = filter(None, [self.oscs.verify_package(xx.key_pkg, source=xx.repoid) for xx in rhsm_2_0_avail])
        rhn_2_0_pkgs = filter(None, [self.oscs.verify_package(xx.key_pkg, source=xx.repoid) for xx in rhn_2_0_avail])
        rhsm_1_2_pkgs = filter(None, [self.oscs.verify_package(xx.key_pkg, source=xx.repoid) for xx in rhsm_1_2_avail])
        rhn_1_2_pkgs = filter(None, [self.oscs.verify_package(xx.key_pkg, source=xx.repoid) for xx in rhn_1_2_avail])
        if rhsm_2_0_pkgs:
            self._sub_ver('rhsm', '2.0')
            return True
        if rhn_2_0_pkgs:
            self._sub_ver('rhn', '2.0')
            return True
        if rhsm_1_2_pkgs:
            self._sub_ver('rhsm', '1.2')
            return True
        if rhn_1_2_pkgs:
            self._sub_ver('rhn', '1.2')
            return True
        if rhsm_2_0_avail:
            self._sub_ver('rhsm', '2.0')
            return True
        if rhn_2_0_avail:
            self._sub_ver('rhn', '2.0')
            return True
        if rhsm_1_2_avail:
            self._sub_ver('rhsm', '1.2')
            return True
        if rhn_1_2_avail:
            self._sub_ver('rhn', '1.2')
            return True
        for fxn_rcheck, sub in [(self.oscs.repo_is_rhsm, 'rhsm'), (self.oscs.repo_is_rhn, 'rhn')]:
            if self.subscription == UNKNOWN:
                for repoid in self.oscs.all_repoids():
                    if fxn_rcheck(repoid) and self._sub_ver(sub):
                        return True
        return False

    def verify_yum_plugin_priorities(self):
        """Make sure the required yum plugin package yum-plugin-priorities is installed

        TODO: Install automatically if --fix is specified?
        """
        self.logger.info('Checking if yum-plugin-priorities is installed')
        if not self.oscs.verify_package('yum-plugin-priorities'):
            if list(self.oscs.yb.searchGenerator(['name'], ['yum-plugin-priorities'])):
                self.logger.error('Required package yum-plugin-priorities is not installed. Install the package with the following command:')
                self.logger.error('# yum install yum-plugin-priorities')
            else:
                self.logger.error('Required package yum-plugin-priorities is not available.')
            return False
        return True

    def _get_pri(self, repolist, minpri=False):
        if minpri:
            return min(chain((self.oscs.repo_priority(xx) for xx in repolist), [99]))
        return max(chain((self.oscs.repo_priority(xx) for xx in repolist), [0]))

    def _set_pri(self, repoid, priority):
        if not self.pri_header:
            self.pri_header = True
            self.logger.info('Resolving repository/channel/subscription priority conflicts')
        if self.opts.fix:
            self.logger.warning("Setting priority for repository %s to %d"%(repoid, priority))
            self.oscs.set_repo_priority(repoid, priority)
        else:
            if not self.pri_resolve_header:
                self.pri_resolve_header = True
                if self.oscs.repo_is_rhn(repoid):
                    self.logger.error("To resolve conflicting repositories, update /yum/pluginconf.d/rhnplugin.conf with the following changes:")
                else:
                    self.logger.error("To resolve conflicting repositories, update repo priority by running:")
            # TODO: in the next version this should read "# subscription-manager override --repo=%s --add=priority:%d"
            if self.oscs.repo_is_rhn(repoid):
                self.logger.error("Set priority=%d in the [%s] section"%(priority, repoid))
            else:
                self.logger.error("# yum-config-manager --setopt=%s.priority=%d %s --save"%(repoid, priority, repoid))

    def _check_valid_pri(self, repos):
        bad_repos = [(xx, self.oscs.repo_priority(xx)) for xx in repos if self.oscs.repo_priority(xx) >= 99]
        if bad_repos:
            self.logger.error('The calculated priorities for the following repoids are too large (>= 99)')
            for repoid, pri in bad_repos:
                self.logger.error('    %s'%repoid)
            self.logger.error('Please re-run this script with the --fix argument to set an appropriate priority, or update the system priorities by hand')
            return False
        return True

    def verify_rhel_priorities(self, ose_repos, rhel6_repo):
        ose_pri = self._get_pri(ose_repos)
        rhel_pri = self.oscs.repo_priority(rhel6_repo)
        if rhel_pri <= ose_pri:
            for repoid in ose_repos:
                self._set_pri(repoid, OSE_PRIORITY)
            ose_pri = OSE_PRIORITY
        if rhel_pri <= ose_pri or rhel_pri >= 99:
            self._set_pri(rhel6_repo, RHEL_PRIORITY)

    def verify_jboss_priorities(self, ose_repos, jboss_repos, rhel6_repo):
        ose_pri = self._get_pri(ose_repos)
        jboss_pri = self._get_pri(jboss_repos, minpri=True)
        jboss_max_pri = self._get_pri(jboss_repos)
        rhel_pri = self.oscs.repo_priority(rhel6_repo)
        if jboss_pri <= rhel_pri or jboss_max_pri >= 99:
            self._set_pri(rhel6_repo, RHEL_PRIORITY)
            for repoid in jboss_repos:
                self._set_pri(repoid, JBOSS_PRIORITY)

    def verify_priorities(self):
        self.logger.info('Checking channel/repository priorities')
        ose = self.blessed_repoids(enabled=True, required=True, product='ose')
        jboss = self.blessed_repoids(enabled=True, required=True, product='jboss')
        rhel = self.blessed_repoids(product='rhel')[0]
        self.verify_rhel_priorities(ose, rhel)
        if jboss:
            self.verify_jboss_priorities(ose, jboss, rhel)
        return True

    def check_disabled_repos(self):
        disabled_repos = list(set(self.blessed_repoids(required = True)).intersection(self.oscs.disabled_repoids()))
        if disabled_repos:
            if self.opts.fix:
                for ii in disabled_repos:
                    if self.oscs.enable_repo(ii):
                        self.logger.warning('Enabled repository %s'%ii)
            else:
                self.logger.error("The required OpenShift Enterprise repositories are disabled: %s"%disabled_repos)
                if self.subscription == RHN:
                    self.logger.error('Make the following modifications to /etc/yum/pluginconf.d/rhnplugin.conf')
                else:
                    self.logger.error("Enable these repositories with the following commands:")
                for repoid in disabled_repos:
                    if self.subscription == RHN:
                        self.logger.error("    Set enabled=1 in the [%s] section"%repoid)
                    elif self.subscription == RHSM:
                        self.logger.error("# subscription-manager repos --enable=%s"%repoid)
                    else:
                        self.logger.error("# yum-config-manager --enable %s"%repoid)
        return True

    def check_missing_repos(self):
        missing_repos = [repo for repo in self.blessed_repoids(required = True) if repo not in self.oscs.all_repoids()]
        if missing_repos:
            self.logger.error("The required OpenShift Enterprise repositories are missing: %s"%missing_repos)
            if self.subscription == RHSM:
                self.logger.error('Follow the instructions at the following URL to add the necessary subscriptions for the selected roles: https://access.redhat.com/site/documentation//en-US/OpenShift_Enterprise/1/html/Deployment_Guide/chap-Installing_and_Configuring_Node_Hosts.html#Using_Red_Hat_Subscription_Management1')
                self.logger.error('After adding the subscriptions, verify that the following repoids are available and enabled:')
                for repoid in missing_repos:
                    self.logger.error("    %s"%repoid)
            elif self.subscription == RHN:
                self.logger.error("Add the missing repositories with the following commands:")
                for repoid in missing_repos:
                    self.logger.error("# rhn-channel -a -c %s"%repoid)
        return True             # Needed?

    def verify_repo_priority(self, repoid, required_repos):
        """Checks the given repoid to make sure that the priority for it
        doesn't conflict with required repository priorities

        Preconditions: Maximum OpenShift (and blessed) repository
        priority should be below 99
        """
        required_pri = self._get_pri(required_repos)
        new_pri = OTHER_PRIORITY
        if self.oscs.repo_priority(repoid) <= required_pri:
            if required_pri >= new_pri:
                new_pri = min(99, required_pri+10)
            self._set_pri(repoid, new_pri)

    def find_package_conflicts(self):
        self.pri_resolve_header = False
        all_blessed_repos = repo_db.find_repoids(product_version = self.opts.oo_version)
        enabled_ose_repos = self.blessed_repoids(enabled = True, required = True, product = 'ose')
        enabled_jboss_repos = self.blessed_repoids(enabled = True, required = True, product = 'jboss')
        rhel6_repo = self.blessed_repoids(product='rhel')
        required_repos = enabled_ose_repos + rhel6_repo + enabled_jboss_repos
        if not self._check_valid_pri(required_repos):
            return False
        for repoid in required_repos:
            try:
                ose_pkgs = self.oscs.packages_for_repo(repoid, disable_priorities = True)
            except KeyError as ke:
                self.logger.error('Repository %s not enabled'%ke.message)
            ose_pkg_names = sorted(set([xx.name for xx in ose_pkgs]))
            # print "ose_pkg_names count: %d"%(len(ose_pkg_names))
            # print "ose_pkg_names: "
            # map(sys.stdout.write, ('    %s\n'%xx for xx in ose_pkg_names))
            other_pkg_matches = [xx for xx in self.oscs.all_packages_matching(ose_pkg_names, True) if xx.repoid not in all_blessed_repos]
            conflicts = sorted(set([xx.repoid for xx in other_pkg_matches]))
            # map(sys.stdout.write, ('nvr: %s-%s-%s   repoid: %s\n'%(xx.name, xx.ver, xx.release, xx.repoid) for xx in other_pkg_matches))
            for ii in conflicts:
                self.verify_repo_priority(ii, required_repos)
        return True

    def guess_role(self):
        self.logger.warning('No roles have been specified. Attempting to guess the roles for this system...')
        self.opts.role = []
        if self.oscs.verify_package('openshift-origin-broker'):
            self.opts.role.append('broker')
        if self.oscs.verify_package('rubygem-openshift-origin-node'):
            self.opts.role.append('node')
        if self.oscs.verify_package('rhc'):
            self.opts.role.append('client')
        if self.oscs.verify_package('openshift-origin-cartridge-jbosseap'):
            self.opts.role.append('node-eap')
        if not self.opts.role:
            self.logger.error('No roles could be detected.')
            return False
        self.logger.warning('If the roles listed below are incorrect or incomplete, please re-run this script with the appropriate --role arguments')
        self.logger.warning('\n'.join(('    %s'%role for role in self.opts.role)))
        return True

    def validate_roles(self):
        if not self.opts.role:
            return True
        for role in self.opts.role:
            if not role in self.valid_roles:
                self.logger.error('You have specified an invalid role: %s is not one of %s'%(role, self.valid_roles))
                self.opt_parser.print_help()
                return False
        return True

    def validate_version(self):
        if self.opts.oo_version:
            if not self.opts.oo_version in self.valid_oo_versions:
                self.logger.error('You have specified an invalid version: %s is not one of %s'%(self.opts.oo_version, self.valid_oo_versions))
                self.opt_parser.print_help()
                return False
        return True

    def massage_roles(self):
        if not self.opts.role:
            self.guess_role()
        if self.opts.role:
            self.opts.role = [xx.lower() for xx in self.opts.role]
            if 'node-eap' in self.opts.role and not 'node' in self.opts.role:
                self.opts.role.append('node')
            if 'node' in self.opts.role and not 'node-eap' in self.opts.role:
                self.logger.warning('If this system will be providing the JBossEAP cartridge, re-run this command with the --role=node-eap argument')

    def main(self):
        if not self.validate_roles():
            return False
        self.massage_roles()
        if not self.guess_ose_version():
            if self.subscription == UNKNOWN:
                self.logger.error('Could not determine subscription type. Register your system to RHSM or RHN.')
            if not self.opts.oo_version:
                self.logger.error('Could not determine product version. Please re-run this script with the --oo_version argument.')
            return False
        yum_plugin_priorities = self.verify_yum_plugin_priorities()
        self.check_disabled_repos()
        self.check_missing_repos()
        if not yum_plugin_priorities:
            self.logger.warning('Skipping yum priorities verification')
            if not self.opts.role:
                self.logger.warning('Please specify at least one role for this system with the --role command')
        else:
            self.verify_priorities()
            self.find_package_conflicts()
        if not self.opts.fix:
            self.logger.info('Please re-run this tool after making any recommended repairs to this system')
        # oacs.do_report()


if __name__ == "__main__":
    ROLE_HELP='Role of this server (broker, node, node-eap, client)'
    OO_VERSION_HELP='Version of OpenShift Enterprise in use on this system (1.2, 2.0, etc.)'


    try:
        import argparse
        opt_parser = argparse.ArgumentParser()
        opt_parser.add_argument('-r', '--role', default=None, type=str, action='append', help=ROLE_HELP)
        opt_parser.add_argument('-o', '--oo_version', default=None, type=str, help=OO_VERSION_HELP)
        opt_parser.add_argument('-f', '--fix', action='store_true', help='If set, attempt to repair issues as well as warn')
        opts = opt_parser.parse_args()
    except ImportError:
        import optparse
        opt_parser = optparse.OptionParser()
        opt_parser.add_option('-r', '--role', default=None, type='string', action='append', help=ROLE_HELP)
        opt_parser.add_option('-o', '--oo_version', default=None, type='string', help=OO_VERSION_HELP)
        opt_parser.add_option('-f', '--fix', action='store_true', help='If set, attempt to repair issues as well as warn')
        (opts, args) = opt_parser.parse_args()
    oacs = OpenShiftAdminCheckSources(opts, opt_parser)
    oacs.main()
