#!/usr/bin/python -tt

import sys
import os
# import yum
from yum import config
from yum import plugins
from yum.Errors import RepoError
import time
import shutil
sys.path.insert(0,'/usr/share/yum-cli')
from utils import YumUtilBase
from iniparse import INIConfig
from collections import namedtuple
from optparse import OptionParser

NAME = 'oo-admin-check-sources'
VERSION = '0.1'
USAGE = 'Apply a thin layer to scalp and sing'
RHNPLUGINCONF = '/etc/yum/pluginconf.d/rhnplugin.conf'

class OpenShiftCheckSources:
    conf_backups = {}

    def __init__(self, name = NAME, ver = VERSION, usage = USAGE):
        self._init_yumbase(name, ver, usage)
        try:
            import rhnplugin
            self.imported_rhnplugin = True
        except ImportError:
            self.imported_rhnplugin = False
        # self.opts = self.yb.doUtilConfigSetup()

    def _init_yumbase(self, name = NAME, ver = VERSION, usage = USAGE):
        self.yb = YumUtilBase(name, ver, usage)
        self.yb.preconf.disableplugin = []
        self.yb.preconf.quiet = True
        self.yb.preconf.debuglevel = -1
        self.yb.preconf.errorlevel = -1
        self.yb.preconf.plugin_types = (plugins.TYPE_CORE, plugins.TYPE_INTERACTIVE)
        op = OptionParser()
        self.yb.preconf.optparser = op
        self.yb.conf.cache = os.geteuid() != 0
        self.yb.conf.disable_excludes = []
        opts, args = op.parse_args([])
        # The yum security plugin will crap pants if the plugin
        # cmdline isn't set up:
        self.yb.plugins.setCmdLine(opts, args)

    def _yb_no_pri(self):
        npyb = YumUtilBase(NAME, VERSION, USAGE)
        npyb.preconf.disabled_plugins = ['priorities']
        npyb.preconf.quiet = True
        npyb.preconf.debuglevel = -1
        npyb.preconf.errorlevel = -1
        op = OptionParser()
        npyb.preconf.optparser = op
        npyb.conf.cache = os.geteuid() != 0
        npyb.conf.disable_excludes = ['all']
        opts, args = op.parse_args([])
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
        backup_filepath = '%s.backup_%s'%(filepath, time.strftime('%Y%m%d-%H%M%S'))
        self.conf_backups[filepath] = backup_filepath
        shutil.copy2(filepath, backup_filepath)
        return backup_filepath

    def _resolve_repoid(self, repoid):
        try:
            repo = self.yb.repos.getRepo(repoid)
        except AttributeError:
            repo = repoid
        return repo

    def repo_priority(self, repoid):
        """Return the configured priority for the repository identified by repoid

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
        # repo.setAttribute('priority', priority)
        # self.backup_config(RHNPLUGINCONF)
        # cfg = INIConfig(file(RHNPLUGINCONF))
        # repocfg = getattr(cfg, repo.id)
        # repocfg.priority = priority
        # ff = open(RHNPLUGINCONF, 'w')
        # print >>ff, cfg
        # ff.close()
        self._set_save_repo_attr(repo, 'priority', priority)

    def _set_save_repo_attr(self, repo, attribute, value):
        """Set the priority for the given RHN repo

        Arguments:
        repo -- rhnplugin.RhnRepo object representing the
                repository to be updated
        attribute -- str representing repository configuration
                     attribute to be updated (e.g. 'priority')
        value -- updated value for specified attribute
        """
        repo.setAttribute(attribute, value)
        if self.repo_is_rhn(repo):
            self.backup_config(RHNPLUGINCONF)
            cfg = INIConfig(file(RHNPLUGINCONF))
            repocfg = getattr(cfg, repo.id)
            setattr(repocfg, attribute, value)
            ff = open(RHNPLUGINCONF, 'w')
            print >>ff, cfg
            ff.close()
        else:
            self.backup_config(repo.repofile)
            config.writeRawRepoFile(repo, only=[attribute])
        # self._init_yumbase()

    def repo_is_rhsm(self, repoid):
        """Given a YumRepository instance or a repoid, try to detect if it's from a subscription-manager managed source

        TODO: This will be UNRELIABLE in the next subscription-manager
        iteration - The is_managed function from here should be used
        instead:
        https://github.com/candlepin/subscription-manager/blob/awood/content-override/src/subscription_manager/repolib.py#L46
        """
        repo = self._resolve_repoid(repoid)
        return getattr(repo, 'repofile', None) == '///etc/yum.repos.d/redhat.repo'

    def repo_is_rhn(self, repoid):
        """Given a YumRepository instance or a repoid, try to detect if it's from an RHN Classic subscription
        """
        repo = self._resolve_repoid(repoid)
        # return '%s'%repo.__class__ == "<class 'rhnplugin.RhnRepo'>" # THIS IS A SERIOUSLY UNHEALTHY HACK?!
        return repo.__class__.__module__ == 'rhnplugin' # This is a slightly less unhealthy hack

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
        if self.repo_is_rhn(repo):
            self._rhn_set_repo_priority(repo, priority)
        else:
            # repo is a yum/rhsm repo!
            try:
                repo.priority = priority
            except AttributeError:
                # Not sure if this is needed or if it would even work...
                repo.setConfigOption('priority', priority)
            self.backup_config(repo.repofile)
            config.writeRawRepoFile(repo, only=['priority'])

    def enable_repo(self, repoid):
        """Enable the repository for the given repoid

        Return false if the repoid doesn't identify a subscribed repository.
        """
        try:
            repo = self._resolve_repoid(repoid)
            if not repo.isEnabled():
                repo.enable()
            self._set_save_repo_attr(repo, 'enabled', True)
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
            self._set_save_repo_attr(repo, 'enabled', False)
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
            repos = self.yb.repos.listEnabled()
        else:
            repos = self.yb.repos.repos.values()
        return sorted(repos, key=self.repo_priority)

    def repoids(self, repos=None):
        """Returns a list of repoids for all repositories in repos

        Arguments:
        repos -- a List of YumRepository objects
        """
        if not repos:
            # repos = self.all_repos()
            return []
        return [repo.id for repo in repos]

    def all_repos(self):
        """Returns a list of all configured repositories"""
        return self.yb.repos.repos.values()

    def all_repoids(self):
        """Returns a list of repoids for all currently enabled repositories"""
        return self.repoids(self.all_repos())

    def enabled_repos(self):
        """Returns a list of all currently enabled repositories"""
        return self.yb.repos.listEnabled()

    def enabled_repoids(self):
        """Returns a list of repoids for all currently enabled repositories"""
        return self.repoids(self.enabled_repos())

    def disabled_repos(self):
        """Returns a list of all currently disabled repositories"""
        return [repo for repo in self.yb.repos.repos.values() if not repo.isEnabled()]

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
            apkgs = self.yb.pkgSack.searchPkgTuple(pkg.pkgtup)
            try:
                pkg = apkgs[0]
                return pkg.repoid
            except IndexError:
                print "Package %s was not found in any repository."
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
        return self.yb.pkgSack.searchNames(pkg_names)

    def packages_for_repo(self, repoid, disable_priorities=False):
        """Return the list of all packages provided by a given repoid
        """
        if disable_priorities:
            return self._yb_no_pri().pkgSack.returnPackages(repoid=repoid)
        return self.yb.pkgSack.returnPackages(repoid=repoid)

    def package_available(self, name):
        sg = self.yb.searchGenerator(['name'], [name])
        return next((pkg for pkg in sg if pkg[0].name == name), None)

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
        pkgs = self.yb.doPackageLists(pkgnarrow='installed', patterns=[name])
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
    oscs  = OpenShiftCheckSources(name, ver, usage)
    print "oscs.order_repos_by_priority: %s"%oscs.order_repos_by_priority()

if __name__ == '__main__':
    main()
