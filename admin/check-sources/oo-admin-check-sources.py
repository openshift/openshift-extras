#!/usr/bin/python -tt

import sys
from check_sources import OpenShiftCheckSources
from itertools import chain

OSE_PRIORITY = 10
RHEL_PRIORITY = 20
JBOSS_PRIORITY = 30
OTHER_PRIORITY = 40

class OpenShiftAdminCheckSources:
    valid_roles = ['node', 'broker', 'client', 'node-eap']

    pri_header = False
    pri_resolve_header = False

    rhn_ose_repos = {'node': 'rhel-x86_64-server-6-ose-1.2-node',
                     'broker': 'rhel-x86_64-server-6-ose-1.2-infrastructure',
                     'client': 'rhel-x86_64-server-6-ose-1.2-rhc',
                     'node-eap': 'rhel-x86_64-server-6-ose-1.2-jbosseap'}
    rhsm_ose_repos = {'node':  'rhel-server-ose-1.2-node-6-rpms',
                      'broker': 'rhel-server-ose-1.2-infra-6-rpms',
                      'client': 'rhel-server-ose-1.2-rhc-6-rpms',
                      'node-eap':  'rhel-server-ose-1.2-jbosseap-6-rpms'}

    rhsm_rhel6_repo = 'rhel-6-server-rpms'
    rhn_rhel6_repo = 'rhel-x86_64-server-6'

    rhn_jboss_repos = {'node': 'jb-ews-2-x86_64-server-6-rpm',
                       'node-eap': 'jbappplatform-6-x86_64-server-6-rpm'}

    rhsm_jboss_repos = {'node': 'jb-ews-2-for-rhel-6-server-rpms',
                        'node-eap': 'jb-eap-6-for-rhel-6-server-rpms'}

    required_rhn_repos = []
    required_rhsm_repos = []
    uses_rhn = False
    uses_rhsm = False
    report_sections = ['start', 'missing', 'priority', 'end']

    def __init__(self, opts, opt_parser):
        self.opts = opts
        self.opt_parser = opt_parser
        self.oscs = OpenShiftCheckSources()
        self.report = {}
        if not self.opts.role:
            self.guess_role()
        if self.opts.role:
            self.opts.role = [xx.lower() for xx in self.opts.role]
            if not (set(self.valid_roles).intersection(self.opts.role)):
                self.help_quit()
            if 'node-eap' in self.opts.role and not 'node' in self.opts.role:
                self.opts.role.append('node')
            # There has to be a better way...
            self.required_rhn_repos = filter(None, [self.rhn_ose_repos.get(xx) for xx in self.opts.role])
            self.required_rhn_repos += filter(None, [self.rhn_jboss_repos.get(xx) for xx in self.opts.role])
            self.required_rhsm_repos = filter(None, [self.rhsm_ose_repos.get(xx) for xx in self.opts.role])
            self.required_rhsm_repos += filter(None, [self.rhsm_jboss_repos.get(xx) for xx in self.opts.role])
        self.calculate_enabled_repos()
        self.uses_rhn = set(self.rhn_ose_repos.values() + self.rhn_jboss_repos.values()).intersection(self.oscs.enabled_repoids())
        self.uses_rhsm = set(self.rhsm_ose_repos.values() + self.rhsm_jboss_repos.values()).intersection(self.oscs.enabled_repoids())

    def calculate_enabled_repos(self):
        enabled = self.oscs.repoids(self.oscs.order_repos_by_priority())
        self.enabled_rhsm_ose_repos   = list(set(self.rhsm_ose_repos.values()).intersection(enabled, self.required_rhsm_repos))
        self.enabled_rhn_ose_repos    = list(set(self.rhn_ose_repos.values()).intersection(enabled, self.required_rhn_repos))
        self.enabled_rhsm_jboss_repos = list(set(self.rhsm_jboss_repos.values()).intersection(enabled, self.required_rhsm_repos))
        self.enabled_rhn_jboss_repos  = list(set(self.rhn_jboss_repos.values()).intersection(enabled, self.required_rhn_repos))

    def help_quit(self, msg=None):
        if msg:
            print msg
        self.opt_parser.print_help()
        sys.exit(1)

    def do_report(self):
        """Output long-form report to log file

        TODO: Add logfile
        """
        for section in self.report_sections:
            if section in self.report:
                sys.stdout.write('\n'.join(self.report[section]))
            print ""

    def _print_report(self, section, msg):
        # TODO: Add "level" field, allow supression of messages by
        # level (DEBUG, INFO, WARNING, ERROR, etc.)
        if not section in self.report:
            self.report[section] = []
        self.report[section].append(msg)
        print msg


    def verify_yum_plugin_priorities(self):
        """Make sure the required yum plugin package yum-plugin-priorities is installed

        TODO: Install automatically if --fix is specified?
        """
        self._print_report('start', 'Checking if yum-plugin-priorities is installed')
        if not self.oscs.verify_package('yum-plugin-priorities'):
            self._print_report('start', 'Required package yum-plugin-priorities is not installed. Install the package with the following command:')
            self._print_report('start', '# yum install yum-plugin-priorities')
            return False
        return True

    def _get_pri(self, repolist, minpri=False):
        if minpri:
            return min(chain((self.oscs.repo_priority(xx) for xx in repolist), [99]))
        return max(chain((self.oscs.repo_priority(xx) for xx in repolist), [0]))

    def _set_pri(self, repoid, priority):
        if not self.pri_header:
            self.pri_header = True
            self._print_report('priority', 'Resolving repository/channel/subscription priority conflicts')
        if self.opts.fix:
            self._print_report('priority', "Setting priority for repository %s to %d"%(repoid, priority))
            self.oscs.set_repo_priority(repoid, priority)
        else:
            if not self.pri_resolve_header:
                self.pri_resolve_header = True
                self._print_report('priority', "To resolve conflicting repositories, update repo priority by running:")
            # TODO: in the next version this should read "# subscription-manager override --repo=%s --add=priority:%d"
            self._print_report('priority', "# yum-config-manager --setopt=%s.priority=%d %s --save"%(repoid, priority, repoid))

    def _check_valid_pri(self, repos):
        bad_repos = [(xx, self.oscs.repo_priority(xx)) for xx in repos if self.oscs.repo_priority(xx) >= 99]
        if bad_repos:
            self._print_report('priority', 'The calculated priorities for the following repoids are too large (>= 99)')
            for repoid, pri in bad_repos:
                self._print_report('priority', '    %s'%repoid)
            self._print_report('priority', 'Please re-run this script with the --fix argument to set an appropriate priority, or update the system priorities by hand')
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
        self._print_report('priority', 'Checking channel/repository priorities')
        if self.uses_rhsm:
            self.verify_rhel_priorities(self.enabled_rhsm_ose_repos, self.rhsm_rhel6_repo)
            if 0 < len(self.enabled_rhsm_jboss_repos):
                self.verify_jboss_priorities(self.enabled_rhsm_ose_repos, self.enabled_rhsm_jboss_repos, self.rhsm_rhel6_repo)
        if self.uses_rhn:
            self.verify_rhel_priorities(self.enabled_rhn_ose_repos, self.rhn_rhel6_repo)
            if 0 < len(self.enabled_rhn_jboss_repos):
                self.verify_jboss_priorities(self.enabled_rhn_ose_repos, self.enabled_rhn_jboss_repos, self.rhn_rhel6_repo)
        return True

    def check_missing_repos(self):
        missing_repos = []
        disabled_repos = []
        for role in self.opts.role:
            if self.uses_rhsm:
                for repoid in filter(None, [self.rhsm_ose_repos.get(role), self.rhsm_jboss_repos.get(role)]):
                    if repoid in self.oscs.disabled_repoids():
                        disabled_repos.append(repoid)
                    elif repoid not in self.oscs.enabled_repoids():
                        missing_repos.append(repoid)
            elif self.uses_rhn:
                for repoid in filter(None, [self.rhn_ose_repos.get(role), self.rhn_jboss_repos.get(role)]):
                    if repoid in self.oscs.disabled_repoids():
                        disabled_repos.append(repoid)
                    elif repoid not in self.oscs.enabled_repoids():
                        missing_repos.append(repoid)
        if disabled_repos:
            if self.opts.fix:
                for ii in disabled_repos:
                    if self.oscs.enable_repo(ii):
                        self._print_report('missing', 'Enabled repository %s'%ii)
                self.calculate_enabled_repos()
            else:
                self._print_report('missing', "The required OpenShift Enterprise repositories are disabled: %s"%disabled_repos)
                if self.uses_rhn:
                    self._print_report('missing', 'Make the following modifications to /etc/yum/pluginconf.d/rhnplugin.conf')
                else:
                    self._print_report('missing', "Enable these repositories with the following commands:")
                for repoid in disabled_repos:
                    if self.uses_rhn:
                        self._print_report('missing', '    Add the [%s] section if missing, and under that make sure that "enabled=1" is set.'%repoid)
                    else:
                        self._print_report('missing', "# yum-config-manager --enablerepo=%s %s --save"%(repoid, repoid))
        if missing_repos:       # Not all of the missing repositories could be enabled
            # if not self.opts.fix:
            if True:
                self._print_report('missing', "The required OpenShift Enterprise repositories are missing: %s"%missing_repos)
                if self.uses_rhsm:
                    self._print_report('missing', 'Follow the instructions at the following URL to add the necessary subscriptions for the selected roles: https://access.redhat.com/site/documentation//en-US/OpenShift_Enterprise/1/html/Deployment_Guide/chap-Installing_and_Configuring_Node_Hosts.html#Using_Red_Hat_Subscription_Management1')
                    self._print_report('missing', 'After adding the subscriptions, verify that the following repoids are available and enabled:')
                    for repoid in missing_repos:
                        self._print_report('missing', "    %s"%repoid)
                elif self.uses_rhn:
                    self._print_report('missing', "Add the missing repositories with the following commands:")
                    for repoid in missing_repos:
                        self._print_report('missing', "# rhn-channel -a -c %s"%repoid)
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
        enabled_ose_repos = list(set(self.required_rhsm_repos + self.required_rhn_repos).intersection(self.enabled_rhsm_ose_repos + self.enabled_rhn_ose_repos))
        # other_ose_repos = list(set(rhn_ose_repos.values() + rhsm_ose_repos.values()).difference(enabled_rhn_ose_repos))
        all_repos = self.rhn_ose_repos.values() + self.rhsm_ose_repos.values() + self.rhsm_jboss_repos.values() + self.rhn_jboss_repos.values() + [self.rhsm_rhel6_repo, self.rhn_rhel6_repo]
        enabled_jboss_repos = list(set(self.required_rhsm_repos + self.required_rhn_repos).intersection(self.enabled_rhsm_jboss_repos + self.enabled_rhn_jboss_repos))
        rhel6_repo = []
        if self.uses_rhsm:
            rhel6_repo = [self.rhsm_rhel6_repo]
        elif self.uses_rhn:
            rhel6_repo = [self.rhn_rhel6_repo]
        required_repos = enabled_ose_repos + rhel6_repo + enabled_jboss_repos
        if not self._check_valid_pri(required_repos):
            return False
        for repoid in required_repos:
            try:
                ose_pkgs = self.oscs.packages_for_repo(repoid, disable_priorities = True)
            except KeyError as ke:
                self._print_report('missing', 'Repository %s not enabled'%ke.message)
            ose_pkg_names = sorted(set([xx.name for xx in ose_pkgs]))
            # print "ose_pkg_names count: %d"%(len(ose_pkg_names))
            # print "ose_pkg_names: "
            # map(sys.stdout.write, ('    %s\n'%xx for xx in ose_pkg_names))
            other_pkg_matches = [xx for xx in self.oscs.all_packages_matching(ose_pkg_names, True) if xx.repoid not in all_repos]
            conflicts = sorted(set([xx.repoid for xx in other_pkg_matches]))
            # map(sys.stdout.write, ('nvr: %s-%s-%s   repoid: %s\n'%(xx.name, xx.ver, xx.release, xx.repoid) for xx in other_pkg_matches))
            for ii in conflicts:
                self.verify_repo_priority(ii, required_repos)
        return True

    def guess_role(self):
        self._print_report('start', 'WARNING: No roles have been specified. Attempting to guess the roles for this system...')
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
            self._print_report('start', 'ERROR: No roles could be detected.')
            return False
        self._print_report('start', 'If the roles listed below are incorrect or incomplete, please re-run this script with the appropriate --role arguments')
        self._print_report('start', '\n'.join(('    %s'%role for role in self.opts.role)))
        return True

    def validate_roles(self):
        for role in self.opts.role:
            if not role in self.valid_roles:
                self._print_report('start', 'ERROR: You have specified an invalid role: %s is not one of %s'%(role, self.valid_roles))
                self.opt_parser.print_help()
                return False
        return True

    def main(self):
        if self.validate_roles():
            if 'node' in self.opts.role and not 'node-eap' in self.opts.role:
                self._print_report('start', 'NOTE: If this system will be providing the JBossEAP cartridge, re-run this command with the --role=node-eap argument')
            yum_plugin_priorities = self.verify_yum_plugin_priorities()
            self.check_missing_repos()
            if not yum_plugin_priorities:
                self._print_report('priority', 'Skipping yum priorities verification')
            else:
                self.verify_priorities()
                self.find_package_conflicts()
            if not self.opts.fix:
                self._print_report('end', 'NOTE: Please re-run this tool after making any recommended repairs to this system')

        # oacs.do_report()


if __name__ == "__main__":
    ROLE_HELP='Role of this server (broker, node, node-eap, client)'

    try:
        import argparse
        opt_parser = argparse.ArgumentParser()
        opt_parser.add_argument('-r', '--role', default=None, type=str, action='append', help=ROLE_HELP)
        opt_parser.add_argument('-f', '--fix', action='store_true', help='If set, attempt to repair issues as well as warn')
        opts = opt_parser.parse_args()
    except ImportError:
        import optparse
        opt_parser = optparse.OptionParser()
        opt_parser.add_option('-r', '--role', default=None, type='string', action='append', help=ROLE_HELP)
        opt_parser.add_option('-f', '--fix', action='store_true', help='If set, attempt to repair issues as well as warn')
        (opts, args) = opt_parser.parse_args()
    oacs = OpenShiftAdminCheckSources(opts, opt_parser)
    oacs.main()
