#!/usr/bin/python -tt

"""This module provides a wrapper class for YumBase - CheckSources -
which provides useful methods for querying and manipulating Yum
repositories

"""

import sys
import os
# import yum
from yum import config
from yum.config import RepoConf
from yum import plugins
from yum.Errors import RepoError
import time
import shutil
sys.path.insert(0,'/usr/share/yum-cli')
from utils import YumUtilBase
from iniparse import INIConfig
from optparse import OptionParser
from os.path import normpath
import subprocess
import rpm

from yumvalidator.reconcile_rhsm_config import SubscriptionManagerNotRegisteredError

NAME = 'oo-admin-check-sources'
VERSION = '0.1'
USAGE = 'Apply a thin layer to scalp and sing'
RHNPLUGINCONF = '/etc/yum/pluginconf.d/rhnplugin.conf'
RHSM_REPO_FILE='/etc/yum.repos.d/redhat.repo'

SUBMAN_OVERRIDE_NVR = ('subscription-manager', '1.10.7', '1')

class SubscriptionManagerError(Exception):
    """subscription-manager failed, but we don't know why. Time to give up!"""
    pass

# TODO Should subclass YumBase?
class CheckSources(object):
    """This class provides tools for interacting with a system's Yum
    repositories and configuration

    """
    conf_backups = {}

    def __init__(self, name = NAME, ver = VERSION, usage = USAGE):
        self.yum_base = self._init_yumbase(name, ver, usage)

    def _init_yumbase(self, name = NAME, ver = VERSION, usage = USAGE):
        yum_base = YumUtilBase(name, ver, usage)
        yum_base.preconf.disableplugin = []
        yum_base.preconf.quiet = True
        yum_base.preconf.debuglevel = -1
        yum_base.preconf.errorlevel = -1
        yum_base.preconf.plugin_types = (plugins.TYPE_CORE,
                                        plugins.TYPE_INTERACTIVE)
        opt_prsr = OptionParser()
        yum_base.preconf.optparser = opt_prsr
        yum_base.conf.cache = os.geteuid() != 0
        yum_base.conf.disable_excludes = []
        opts, args = opt_prsr.parse_args([])
        # The yum security plugin will crap pants if the plugin
        # cmdline isn't set up:
        yum_base.plugins.setCmdLine(opts, args)
        return yum_base

    def _yb_no_pri(self):
        npyb = YumUtilBase(NAME, VERSION, USAGE)
        npyb.preconf.disabled_plugins = ['priorities']
        npyb.preconf.quiet = True
        npyb.preconf.debuglevel = -1
        npyb.preconf.errorlevel = -1
        opt_prsr = OptionParser()
        npyb.preconf.optparser = opt_prsr
        npyb.conf.cache = os.geteuid() != 0
        npyb.conf.disable_excludes = ['all']
        opts, args = opt_prsr.parse_args([])
        npyb.plugins.setCmdLine(opts, args)
        return npyb

    def backup_config(self, filepath):
        """Creates a new backup of the file at filepath if one hasn't yet been
        made this session

        Returns the path to the backup copy
        """
        backup_filepath = self.conf_backups.get(filepath)
        if backup_filepath:
            return backup_filepath
        backup_filepath = ('%s.backup_%s' %
                           (filepath, time.strftime('%Y%m%d-%H%M%S')))
        self.conf_backups[filepath] = backup_filepath
        shutil.copy2(filepath, backup_filepath)
        return backup_filepath

    def _resolve_repoid(self, repoid):
        try:
            repo = self.yum_base.repos.getRepo(repoid)
        except AttributeError:
            repo = repoid
        return repo

    def _check_rhsm_manage_repos(self):
        try:
            from rhsm.config import initConfig
            CFG = initConfig()
            return 0 != int(CFG.get('rhsm', 'manage_repos'))
        except ImportError:
            return False

    def override_supported(self):
        """Returns True if subscription-manager is installed and is a version
        that supports content overrides

        """
        try:
            return self._override_supported
        except AttributeError:
            pkg_sm = self.installed_package_matching('subscription-manager')
            if pkg_sm:
                sm_nvr=(pkg_sm.name, pkg_sm.ver, pkg_sm.rel)
                self._override_supported = (
                    rpm.labelCompare(sm_nvr, SUBMAN_OVERRIDE_NVR) >= 0)
            else:
                self._override_supported = False
        return self._override_supported

    def use_override(self):
        """Returns True if subscription-manager supports content overrides and
        is configured to manage the repository configuration for this
        host

        """
        try:
            return self._use_override
        except AttributeError:
            self._use_override = (self.override_supported() and
                                  self._check_rhsm_manage_repos())
            if self._use_override:
                from yumvalidator.reconcile_rhsm_config import ReconciliationEngine
                # For now we don't need RepoDB, logging, or opts for r_eng
                try:
                    self.r_eng = ReconciliationEngine(self, None, None, None)
                except SubscriptionManagerNotRegisteredError:
                    self._use_override = False
                    raise
                except Exception, rengex:
                    # We can't recover from any error here
                    raise SubscriptionManagerError(repr(rengex))
            return self._use_override

    def _update_overrides(self):
        try:
            (self._repo_overrides, ovrd_repos) = self.r_eng.get_overrides_and_repos()
        except Exception, rengex:
            # We can't recover from any error here
            raise SubscriptionManagerError(repr(rengex))

        self._ovrd_age = time.time()

    def repo_overrides(self):
        """Return a list of content overrides for this host

        """
        cur_time = time.time()
        if not self.use_override():
            return {}
        try:
            if 30 > cur_time - self._ovrd_age:
                self._update_overrides()
        except AttributeError:
            self._update_overrides()
        return self._repo_overrides

    def repo_priority(self, repoid):
        """Return the configured priority for the repository identified
        by repoid

        Arguments:
        repoid -- can be a string with the repository id or an object
                  of type yum.yumRepo.YumRepository

        """
        repo = self._resolve_repoid(repoid)
        try:
            return repo.priority
        except AttributeError:
            return 99

    def _rhn_set_repo_priority(self, repo, priority):
        """Set the priority for the given RHN repo

        Arguments:
        repo -- rhnplugin.RhnRepo object representing the
                repository to be updated
        priority -- Integer value representing the updated
                    repository priority
        """
        self.set_save_repo_attr(repo, 'priority', priority)

    def get_update_override_cmd(self, repo, attribute, value, for_output=False):
        """Get the subscription-manager command line needed to set the given
        attribute on the given repo via repo-override, formatted for
        subprocess.call or for terminal output

        Arguments:
        repo -- str representing repoid or rhnplugin.RhnRepo object
                representing the repository to be updated
        attribute -- str representing repository configuration
                     attribute to be updated (e.g. 'priority')
        value -- updated value for specified attribute, stored as
                 appropriate type (e.g. list for 'exclude' attribute)
        for_output -- bool indicating that the return value is for use
                      with subprocess.call (False, default) or for
                      terminal output
        """
        repo = self._resolve_repoid(repo)
        option = RepoConf.optionobj(attribute)
        if isinstance(option, config.ListOption):
            v_str = ' '.join(value)
            if ' ' in v_str and for_output:
                v_str = '"%s"' % v_str
        else:
            v_str = option.tostring(value)
        response = ['/usr/sbin/subscription-manager',
                    'repo-override',
                    '--repo=%s'%repo.id,
                    '--add=%s:%s' % (attribute, v_str)]
        if for_output:
            response = ' '.join(response)
        return response

    def _set_save_repo_attr_override(self, repo, attribute, value, base_timeout=1, max_retry=3):
        """Set the repo attribute to the given value for the given RHSM repo
        via content override

        Arguments:
        repo -- str repoid or suitable Repo object
        attribute -- str representing repository configuration
                     attribute to be updated (e.g. 'priority')
        value -- updated value for specified attribute
        base_timeout -- number of seconds to sleep between first
                        failure and first retry. Each subsequent
                        timeout is twice as long as the last. Only
                        used for RHSM repos where settings are stored
                        in content overrides. Default: 1, minimum value: 0.25
        max_retry -- number of times to retry a failed repo attribute
                     commit. Only used for RHSM repos where settings
                     are stored in content overrides. Default: 3

        """
        repo = self._resolve_repoid(repo)
        retries = -1
        timeout = max([0.25, base_timeout])
        update_cmd = self.get_update_override_cmd(repo, attribute, value)
        while 0 != subprocess.call(update_cmd):
            retries += 1
            if retries >= max_retry:
                raise SubscriptionManagerError(
                    "subscription-manager failed, with these "
                    "arguments: %s" %
                    self.get_update_override_cmd(repo, attribute,
                                                 value, for_output=True))
            time.sleep(timeout)
            timeout *= 2
        else:
            self.repo_overrides()[repo.id][attribute] = repo.getAttribute(attribute)

    def _set_save_repo_attr_yum(self, repo, attribute, value):
        """Set the repo attribute to the given value for the given Yum or
        Yum-like repo

        Arguments:
        repo -- str repoid or suitable Repo object
        attribute -- str representing repository configuration
                     attribute to be updated (e.g. 'priority')
        value -- updated value for specified attribute

        """
        repo = self._resolve_repoid(repo)
        self.backup_config(repo.repofile)
        config.writeRawRepoFile(repo, only=[attribute])

    def repo_attr_overridden(self, repo, attribute):
        """Returns True if the given repository has a content override
        configured for the given attribute

        Arguments:
        repo -- str repoid or suitable Repo object
        attribute -- str representing repository configuration
                     attribute to be checked for content override
                     (e.g. 'priority')

        """
        repo = self._resolve_repoid(repo)
        return (self.use_override() and
                repo.id in self.repo_overrides() and
                attribute in self.repo_overrides()[repo.id])

    def set_save_repo_attr(self, repo, attribute, value):
        """Set the repo attribute to the given value for the given repo

        Arguments:

        repo -- str representing repoid or rhnplugin.RhnRepo (or
                equivalent) object representing the repository to be
                updated
        attribute -- str representing repository configuration
                     attribute to be updated (e.g. 'priority')
        value -- updated value for specified attribute

        """
        repo = self._resolve_repoid(repo)
        repo.setAttribute(attribute, value)
        if self.repo_is_rhn(repo):
            if hasattr(value, '__iter__'):
                value = ' '.join(value)
            self.backup_config(RHNPLUGINCONF)
            cfg = INIConfig(file(RHNPLUGINCONF))
            repocfg = getattr(cfg, repo.id)
            setattr(repocfg, attribute, value)
            cfg_file = open(RHNPLUGINCONF, 'w')
            print >> cfg_file, cfg
            cfg_file.close()
        elif (self.repo_is_rhsm(repo) and
              self.repo_attr_overridden(repo, attribute)):
            self._set_save_repo_attr_override(repo, attribute, value)
        else:
            self._set_save_repo_attr_yum(repo, attribute, value)

    def repo_for_repoid(self, repoid):
        """Return the YumRepository matching the given repoid
        """
        return self.yum_base.repos.repos[repoid]

    def merge_excludes(self, repo, excludes):
        """Take a list of packages (or globs) to exclude from repo and merge
        them into the existing list of excludes, eliminating
        duplicates.

        """
        repo = self._resolve_repoid(repo)
        try:
            new_excl = list(set(repo.exclude + excludes))
        except TypeError:
            new_excl = list(set(repo.exclude + list(excludes)))
        self.set_save_repo_attr(repo, 'exclude', new_excl)

    def repo_act_invoker(self):
        """Returns a subscription_manager.repolib.RepoActionInvoker object if
        supported, or None

        """
        try:
            return self._repo_act_invoker
        except AttributeError:
            try:
                if not self.override_supported():
                    self._repo_act_invoker = None
                else:
                    if not self.use_override():
                        from subscription_manager.injectioninit import init_dep_injection
                        init_dep_injection()
                    from subscription_manager.repolib import RepoActionInvoker
                    self._repo_act_invoker = RepoActionInvoker()
                    # Check if is_managed() works
                    self._repo_act_invoker.is_managed('this_is-not_a-real_repo')
            except ImportError:
                self._repo_act_invoker = None
            except SubscriptionManagerNotRegisteredError:
                self._repo_act_invoker = None
            except AttributeError: # work around broken repolib implementations
                self._repo_act_invoker = None
        return self._repo_act_invoker

    def repo_is_rhsm(self, repoid):
        """Given a YumRepository instance or a repoid, try to detect if it's
        from a subscription-manager managed source

        TODO: This still works now that subscription-manager supports
        content overrides, but there might be a more reliable
        technique - perhaps the is_managed function from here should
        be used instead:
        https://github.com/candlepin/subscription-manager/blob/awood/content-override/src/subscription_manager/repolib.py#L46

        """
        repo = self._resolve_repoid(repoid)
        if self.override_supported() and self.repo_act_invoker():
            try:
                return self.repo_act_invoker().is_managed(repo.id)
            except Exception, raiex:
                # We can't recover from any error here
                raise SubscriptionManagerError(repr(raiex))
        else:
            try:
                return (repo.sslcacert and
                        repo.sslclientcert and
                        repo.sslclientkey and
                        repo.repofile and
                        (RHSM_REPO_FILE == normpath(repo.repofile)))
            except:
                # If any of those tests raise, it's not likely to be
                # an RHSM repo
                return False
        return False

    def repo_is_rhn(self, repoid):
        """Given a YumRepository instance or a repoid, try to detect if it's
        from an RHN Classic subscription
        """
        repo = self._resolve_repoid(repoid)
        # This is a slightly less unhealthy hack
        return repo.__class__.__module__ == 'rhnplugin'

    def set_repo_priority(self, repoid, priority):
        """Assign the given priority to the repository identified by repoid,
        and save the updated config

        TODO: For RHSM-based repos, it is probably better to set
        options via the ReposCommand object -
        e.g. reposcommand.main(args=['repos', '--enable=REPOID']) - or
        to just shell out to subscription-manager

        The current technique will break in the next version of
        subscription-manager

        """
        repo = self._resolve_repoid(repoid)
        self.set_save_repo_attr(repo, 'priority', priority)

    def enable_repo(self, repoid):
        """Enable the repository for the given repoid

        Return false if the repoid doesn't identify a subscribed repository.
        """
        try:
            repo = self._resolve_repoid(repoid)
            if not repo.isEnabled():
                repo.enable()
            self.set_save_repo_attr(repo, 'enabled', True)
            return True
        except RepoError:
            return False

    def disable_repo(self, repoid):
        """Disable the repository for the given repoid

        Return false if the repoid doesn't identify a subscribed repository.
        """
        try:
            repo = self._resolve_repoid(repoid)
            if repo.isEnabled():
                repo.disable()
            self.set_save_repo_attr(repo, 'enabled', False)
            return True
        except RepoError:
            return False

    def order_repos_by_priority(self, enabled=True):
        """Returns a list of repos ordered by priority

        Keyword arguments:
        enabled -- True to return only currently-enabled repositories,
                   False to include disabled. Defaults to True.
        """
        repos = None
        if enabled:
            repos = self.yum_base.repos.listEnabled()
        else:
            repos = self.yum_base.repos.repos.values()
        return sorted(repos, key=self.repo_priority)

    def repoids(self, repos=None):
        """Returns a list of repoids for all repositories in repos

        Arguments:
        repos -- a List of YumRepository objects
        """
        if not repos:
            return []
        return [repo.id for repo in repos]

    def all_repos(self):
        """Returns a list of all configured repositories"""
        return self.yum_base.repos.repos.values()

    def all_repoids(self):
        """Returns a list of repoids for all currently enabled repositories"""
        return self.repoids(self.all_repos())

    def enabled_repos(self):
        """Returns a list of all currently enabled repositories"""
        return self.yum_base.repos.listEnabled()

    def enabled_repoids(self):
        """Returns a list of repoids for all currently enabled repositories"""
        return self.repoids(self.enabled_repos())

    def disabled_repos(self):
        """Returns a list of all currently disabled repositories"""
        return [repo for repo in self.yum_base.repos.repos.values() if not
                repo.isEnabled()]

    def disabled_repoids(self):
        """Returns a list of repoids for all currently disabled repositories"""
        return self.repoids(self.disabled_repos())

    def repo_for_package(self, pkg):
        """Finds the source repository for the specified package

        Arguments:

        pkg -- an object representing a package that has a yumdb_info
               attribute and a pkgtup attribute (e.g. an object of
               type yum.rpmsack.RPMInstalledPackage)
        """
        if 'from_repo' in pkg.yumdb_info:
            return pkg.yumdb_info.from_repo
        else:
            apkgs = self.yum_base.pkgSack.searchPkgTuple(pkg.pkgtup)
            try:
                pkg = apkgs[0]
                return pkg.repoid
            except IndexError:
                print "Package %s was not found in any repository."
                return None

    def installed_package_matching(self, name):
        """Returns the package object for the first installed package matching
        the specified name
        """
        pkgs = self.yum_base.doPackageLists(pkgnarrow='installed',
                                            patterns=[name])
        try:
            return pkgs.installed[0]
        except IndexError:
            return None
        return None

    def all_packages_matching(self, pkg_names, disable_priorities = False):
        """Return a List of all packages from all enabled repos which match
           the package names in the provided List

        Keyword arguments:
        disable_priorities -- if True, include results which would
                              otherwise be masked by priorities.
                              Default: False

        """
        if disable_priorities:
            return self._yb_no_pri().pkgSack.searchNames(pkg_names)
        return self.yum_base.pkgSack.searchNames(pkg_names)

    def packages_for_repo(self, repoid, disable_priorities=False):
        """Return the list of all packages provided by a given repoid
        """
        if disable_priorities:
            return self._yb_no_pri().pkgSack.returnPackages(repoid=repoid)
        return self.yum_base.pkgSack.returnPackages(repoid=repoid)

    def package_available(self, name):
        srch_gen = self.yum_base.searchGenerator(['name'], [name])
        return next((pkg for pkg in srch_gen if pkg[0].name == name), None)

    def verify_package(self, name, version=None, release=None, source=None):
        """Verifies that the named package matches the provided criteria

        Arguments:
        name -- the full name of the package (e.g. "yum-utils")

        Keyword arguments:
        version -- the expected version of the package (e.g. "1.1.31")
        release -- the expected release tag of the package
                   (e.g. "10.fc18")
        source -- the repoid of the repository expected to provide the
                  package
        """
        pkgs = self.yum_base.doPackageLists(pkgnarrow='installed',
                                            patterns=[name])
        pkg_list = pkgs.installed
        try:
            pkg = pkg_list[0]
        except IndexError:
            return False
        result = pkg.name == name
        if version:
            result &= pkg.version == version
        if release:
            result &= pkg.release == release
        if source:
            result &= self.repo_for_package(pkg) == source
        return result

def main():
    name  = 'testutil'
    ver   = '0.1'
    usage = 'testutil [options] [args]'
    oscs  = CheckSources(name, ver, usage)
    print ("oscs.order_repos_by_priority: %s" %
           oscs.order_repos_by_priority())

if __name__ == '__main__':
    main()
