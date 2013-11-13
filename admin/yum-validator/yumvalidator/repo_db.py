#!/usr/bin/python -tt

"""This provides a quick 'n dirty database for yum-validator tools
(e.g. oo-admin-yum-validator). Here "blessed" repositories can be
defined along with useful metadata, defined in the RepoTuple
namedtuple object. These repository definitions can be queried through
the RepoDB object.

"""

from collections import namedtuple
from copy import copy
from iniparse import INIConfig
from iniparse.config import Undefined
import re
import os.path

RepoTuple = namedtuple('RepoTuple', 'subscription, product, product_version, '
                       'role, repoid, key_pkg, exclude')

DEFAULT_FILES = ['/etc/yum-validator/repos.ini', './etc/repos.ini']

class RepoDBError(Exception):
    """The RepoDB object couldn't be instantiated for some reason"""
    pass

def _repo_tuple_match(repo, match_attr, match_val):
    # Could do this on one line, but this is more readable
    attr = getattr(repo, match_attr, None)
    if match_val == attr:
        return True
    return hasattr(attr, '__iter__') and match_val in attr

def ini_defined(val):
    return not isinstance(val, Undefined)

def parse_multivalue(val):
    if ini_defined(val):
        if val:
            res = tuple(re.split(', ', val))
            if len(res) == 1:
                return res[0]
            return res
    else:
        return None
    return val

def parse_exclude(val):
    tpl = parse_multivalue(val)
    if tpl and not hasattr(tpl, '__iter__'):
        return (tpl,)
    return tpl

class RepoDB:
    """Provides an interface for loading and querying a dataset which
    defines one or more repositories as RepoTuple objects.

    """
    repositories = []
    repo_cache = {}

    def __init__(self, *args, **kwargs):
        if not (args or kwargs):
            self._load_defaults()
        else:
            try:
                if not kwargs['user_repos_only']:
                    self._load_defaults()
                del(kwargs['user_repos_only'])
            except KeyError:
                self._load_defaults()
            self.cfg = INIConfig(*args, **kwargs)
        self.populate_db()

    def _load_defaults(self):
        err_msg = ""
        cfg_file = None
        for cfg_filename in DEFAULT_FILES:
            if os.path.isfile(cfg_filename):
                try:
                    cfg_file = open(cfg_filename, 'r')
                except IOError as io_err:
                    if err_msg:
                        err_msg += "\n"
                    err_msg += "({0})".format(io_err)
        if not cfg_file:
            if not err_msg:
                paths = ', '.join([os.path.abspath(fname) 
                                   for fname in DEFAULT_FILES])
                err_msg = ('Default repository data file could not be '
                           'found in these locations: %s' % paths)
            raise RepoDBError(err_msg)
        self.cfg = INIConfig(cfg_file)
        self.populate_db()

    def populate_db(self):
        for repoid in list(self.cfg):
            repocfg = self.cfg[repoid]
            rtpl = RepoTuple( subscription =
                              parse_multivalue(getattr(repocfg,
                                                       'subscription', None)),
                              product =
                              parse_multivalue(getattr(repocfg, 'product',
                                                       None)),
                              product_version =
                              parse_multivalue(getattr(repocfg,
                                                       'product_version',
                                                       None)),
                              role =
                              parse_multivalue(getattr(repocfg, 'role', None)),
                              repoid = repoid,
                              key_pkg =
                              parse_multivalue(getattr(repocfg, 'key_pkg',
                                                       None)),
                              exclude =
                              parse_exclude(getattr(repocfg, 'exclude', None)))
            if not rtpl in self.repositories:
                self.repositories.append(rtpl)

    def find_repos(self, **kwargs):
        """Return (and cache) tuple of RepoTuples that match the criteria
        specified
        """
        if len(self.repo_cache) > 512:
            # Try to keep the repo_cache from growing infinitely
            # (Guessing 512 is too big is cheaper than calculating the actual
            # mem footprint)
            self.repo_cache = {}
        hkey = tuple(sorted(kwargs.items()))
        if None == self.repo_cache.get(hkey, None):
            repos = copy(self.repositories)
            for key, val in kwargs.items():
                # print key, val
                repos = [repo for repo in repos if
                         _repo_tuple_match(repo, key, val)]
                # print repos
                if not repos:
                    break
            repos = tuple(repos)
            self.repo_cache[hkey] = repos
            return repos
        return self.repo_cache[hkey]

    def find_repoids(self, **kwargs):
        """Return list of repoids for cooresponding results from find_repos

        """
        return [repo.repoid for repo in self.find_repos(**kwargs)]

    def find_repos_by_repoid(self, repoids):
        """Return tuple of RepoTuples which match the list of repoids provided

        """
        if hasattr(repoids, '__iter__'):
            res = []
            for r_id in repoids:
                res += self.find_repos(repoid = r_id)
            return tuple(set(res)) # make unique
        return self.find_repos(repoid = repoids)


if __name__ == '__main__':
    rdb = RepoDB()
    print "find_repos(subscription = 'rhsm'):"
    for xx in rdb.find_repos(subscription = 'rhsm'):
        print xx
    print ""
    print "find_repos(product_version = '1.2'):"
    for xx in rdb.find_repos(product_version = '1.2'):
        print xx
    print ""
    print "find_repos(product_version = '1.2', role = 'node'):"
    for xx in rdb.find_repos(product_version = '1.2', role = 'node'):
        print xx
    print ""
    print "find_repos_by_repoid('rhel-x86_64-server-6-ose-2.0-infrastructure'):"
    for xx in \
        rdb.find_repos_by_repoid('rhel-x86_64-server-6-ose-2.0-infrastructure'):
        print xx
    print ""
    print ("find_repos_by_repoid(['rhel-x86_64-server-6-ose-2.0-infrastructure'"
           ", 'jbappplatform-6-x86_64-server-6-rpm']):")
    for xx in \
        rdb.find_repos_by_repoid(['rhel-x86_64-server-6-ose-2.0-infrastructure',
                                  'jbappplatform-6-x86_64-server-6-rpm']):
        print xx
    print ""
    print ("find_repoids(subscription = 'rhn', role = 'node-eap', "
           "product_version = '1.2'):")
    for xx in rdb.find_repoids(subscription='rhn', role='node-eap',
                               product_version='1.2'):
        print xx
