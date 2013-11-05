#!/usr/bin/python -tt
from collections import namedtuple
from copy import copy
from iniparse import INIConfig
import re

RepoTuple = namedtuple('RepoTuple', 'subscription, product, product_version, role, repoid, key_pkg')

repo_ini = """# RHSM Common

[rhel-6-server-rpms]
subscription = rhsm
product = rhel
product_version = 1.2, 2.0
role = base
key_pkg = None

[jb-ews-2-for-rhel-6-server-rpms]
subscription = rhsm
product = jboss
product_version = 1.2, 2.0
role = node
key_pkg = openshift-origin-cartridge-jbossews

[jb-eap-6-for-rhel-6-server-rpms]
subscription = rhsm
product = jboss
product_version = 1.2, 2.0
role = node-eap
key_pkg = openshift-origin-cartridge-jbosseap

[rhel-server-rhscl-6-rpms]
subscription = rhsm
product = rhscl
product_version = 1.2, 2.0
role = node, broker
key_pkg = ruby193
# RHSM 1.2 repos

[rhel-server-ose-1.2-node-6-rpms]
subscription = rhsm
product = ose
product_version = 1.2
role = node
key_pkg = rubygem-openshift-origin-node

[rhel-server-ose-1.2-infra-6-rpms]
subscription = rhsm
product = ose
product_version = 1.2
role = broker
key_pkg = openshift-origin-broker

[rhel-server-ose-1.2-rhc-6-rpms]
subscription = rhsm
product = ose
product_version = 1.2
role = client
key_pkg = rhc

[rhel-server-ose-1.2-jbosseap-6-rpms]
subscription = rhsm
product = ose
product_version = 1.2
role = node-eap
key_pkg = openshift-origin-cartridge-jbosseap
# RHSM 2.0 repos

[rhel-6-server-ose-2.0-node-rpms]
subscription = rhsm
product = ose
product_version = 2.0
role = node
key_pkg = rubygem-openshift-origin-node

[rhel-6-server-ose-2.0-infra-rpms]
subscription = rhsm
product = ose
product_version = 2.0
role = broker
key_pkg = openshift-origin-broker

[rhel-6-server-ose-2.0-rhc-rpms]
subscription = rhsm
product = ose
product_version = 2.0
role = client
key_pkg = rhc

[rhel-6-server-ose-2.0-jbosseap-rpms]
subscription = rhsm
product = ose
product_version = 2.0
role = node-eap
key_pkg = openshift-origin-cartridge-jbosseap
# RHN Common

[rhel-x86_64-server-6]
subscription = rhn
product = rhel
product_version = 1.2, 2.0
role = base
key_pkg = None

[jb-ews-2-x86_64-server-6-rpm]
subscription = rhn
product = jboss
product_version = 1.2, 2.0
role = node
key_pkg = openshift-origin-cartridge-jbossews

[jbappplatform-6-x86_64-server-6-rpm]
subscription = rhn
product = jboss
product_version = 1.2, 2.0
role = node-eap
key_pkg = openshift-origin-cartridge-jbosseap

[rhel-x86_64-server-6-rhscl-1]
subscription = rhn
product = rhscl
product_version = 1.2, 2.0
role = node, broker
key_pkg = ruby193
# RHN 1.2 repos

[rhel-x86_64-server-6-ose-1.2-node]
subscription = rhn
product = ose
product_version = 1.2
role = node
key_pkg = rubygem-openshift-origin-node

[rhel-x86_64-server-6-ose-1.2-infrastructure]
subscription = rhn
product = ose
product_version = 1.2
role = broker
key_pkg = openshift-origin-broker

[rhel-x86_64-server-6-ose-1.2-rhc]
subscription = rhn
product = ose
product_version = 1.2
role = client
key_pkg = rhc

[rhel-x86_64-server-6-ose-1.2-jbosseap]
subscription = rhn
product = ose
product_version = 1.2
role = node-eap
key_pkg = openshift-origin-cartridge-jbosseap
# RHN 2.0 repos

[rhel-x86_64-server-6-ose-2.0-node]
subscription = rhn
product = ose
product_version = 2.0
role = node
key_pkg = rubygem-openshift-origin-node

[rhel-x86_64-server-6-ose-2.0-infrastructure]
subscription = rhn
product = ose
product_version = 2.0
role = broker
key_pkg = openshift-origin-broker

[rhel-x86_64-server-6-ose-2.0-rhc]
subscription = rhn
product = ose
product_version = 2.0
role = client
key_pkg = rhc

[rhel-x86_64-server-6-ose-2.0-jbosseap]
subscription = rhn
product = ose
product_version = 2.0
role = node-eap
key_pkg = openshift-origin-cartridge-jbosseap
"""

repo_cache = {}

def _repo_tuple_match(repo, match_attr, match_val):
    # Could do this on one line, but this is more readable
    attr = getattr(repo, match_attr, None)
    if match_val == attr:
        return True
    return hasattr(attr, '__iter__') and match_val in attr

def parse_multivalue(val):
    if val:
        rv = tuple(re.split(', ', val))
        if len(rv) == 1:
            return rv[0]
        return rv
    return val

class RepoDB:
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
        from cStringIO import StringIO
        self.cfg = INIConfig(StringIO(repo_ini))
        self.populate_db()

    def populate_db(self):
        for ii in list(self.cfg):
            rt = RepoTuple(
                subscription =    parse_multivalue(self.cfg[ii]['subscription']),
                product =         parse_multivalue(self.cfg[ii]['product']),
                product_version = parse_multivalue(self.cfg[ii]['product_version']),
                role =            parse_multivalue(self.cfg[ii]['role']),
                repoid =          ii,
                key_pkg =         parse_multivalue(self.cfg[ii]['key_pkg']))
            if not rt in self.repositories:
                self.repositories.append(rt)

    def find_repos(self, **kwargs):
        """Return (and cache) tuple of RepoTuples that match the criteria specified
        """
        if len(self.repo_cache) > 512:
            # Try to keep the repo_cache from growing infinitely
            # (Guessing 512 is too big is cheaper than calculating the actual mem footprint)
            self.repo_cache = {}
        hkey = tuple(sorted(kwargs.items()))
        if None == self.repo_cache.get(hkey, None):
            repos = copy(self.repositories)
            for kk, vv in kwargs.items():
                # print kk, vv
                repos = [repo for repo in repos if _repo_tuple_match(repo, kk, vv)]
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
    rd = RepoDB()
    print "find_repos(subscription = 'rhsm'):"
    for xx in rd.find_repos(subscription = 'rhsm'):
        print xx
    print ""
    print "find_repos(product_version = '1.2'):"
    for xx in rd.find_repos(product_version = '1.2'):
        print xx
    print ""
    print "find_repos(product_version = '1.2', role = 'node'):"
    for xx in rd.find_repos(product_version = '1.2', role = 'node'):
        print xx
    print ""
    print "find_repos_by_repoid('rhel-x86_64-server-6-ose-2.0-infrastructure'):"
    for xx in rd.find_repos_by_repoid('rhel-x86_64-server-6-ose-2.0-infrastructure'):
        print xx
    print ""
    print "find_repos_by_repoid(['rhel-x86_64-server-6-ose-2.0-infrastructure', 'jbappplatform-6-x86_64-server-6-rpm']):"
    for xx in rd.find_repos_by_repoid(['rhel-x86_64-server-6-ose-2.0-infrastructure', 'jbappplatform-6-x86_64-server-6-rpm']):
        print xx
    print ""
    print "find_repoids(subscription = 'rhn', role = 'node-eap', product_version = '1.2'):"
    for xx in rd.find_repoids(subscription = 'rhn', role = 'node-eap', product_version = '1.2'):
        print xx
