#!/usr/bin/python -tt
from collections import namedtuple
from copy import copy

RepoTuple = namedtuple('RepoTuple', 'subscription, product, product_version, role, repoid, key_pkg')

repositories = [
    # RHSM Common
    RepoTuple(subscription = 'rhsm',
              product = 'rhel',
              product_version = ('1.2', '2.0'),
              role = 'base',
              repoid = 'rhel-6-server-rpms',
              key_pkg = None),
    RepoTuple(subscription = 'rhsm',
              product = 'jboss',
              product_version = ('1.2', '2.0'),
              role = 'node',
              repoid = 'jb-ews-2-for-rhel-6-server-rpms',
              key_pkg = 'openshift-origin-cartridge-jbossews'),
    RepoTuple(subscription = 'rhsm',
              product = 'jboss',
              product_version = ('1.2', '2.0'),
              role = 'node-eap',
              repoid = 'jb-eap-6-for-rhel-6-server-rpms',
              key_pkg = 'openshift-origin-cartridge-jbosseap'),
]

repositories += [
    # RHSM 1.2 repos
    RepoTuple(subscription = 'rhsm',
              product = 'ose',
              product_version = '1.2',
              role = 'node',
              repoid = 'rhel-server-ose-1.2-node-6-rpms',
              key_pkg = 'rubygem-openshift-origin-node'),
    RepoTuple(subscription = 'rhsm',
              product = 'ose',
              product_version = '1.2',
              role = 'broker',
              repoid = 'rhel-server-ose-1.2-infra-6-rpms',
              key_pkg = 'openshift-origin-broker'),
    RepoTuple(subscription = 'rhsm',
              product = 'ose',
              product_version = '1.2',
              role = 'client',
              repoid = 'rhel-server-ose-1.2-rhc-6-rpms',
              key_pkg = 'rhc'),
    RepoTuple(subscription = 'rhsm',
              product = 'ose',
              product_version = '1.2',
              role = 'node-eap',
              repoid = 'rhel-server-ose-1.2-jbosseap-6-rpms',
              key_pkg = 'openshift-origin-cartridge-jbosseap'),
]

repositories += [
    # RHSM 2.0 repos
    RepoTuple(subscription = 'rhsm',
              product = 'ose',
              product_version = '2.0',
              role = 'node',
              repoid = 'rhel-6-server-ose-2.0-node-rpms',
              key_pkg = 'rubygem-openshift-origin-node'),
    RepoTuple(subscription = 'rhsm',
              product = 'ose',
              product_version = '2.0',
              role = 'broker',
              repoid = 'rhel-6-server-ose-2.0-infra-rpms',
              key_pkg = 'openshift-origin-broker'),
    RepoTuple(subscription = 'rhsm',
              product = 'ose',
              product_version = '2.0',
              role = 'client',
              repoid = 'rhel-6-server-ose-2.0-rhc-rpms',
              key_pkg = 'rhc'),
    RepoTuple(subscription = 'rhsm',
              product = 'ose',
              product_version = '2.0',
              role = 'node-eap',
              repoid = 'rhel-6-server-ose-2.0-jbosseap-rpms',
              key_pkg = 'openshift-origin-cartridge-jbosseap'),
]

repositories += [
    # RHN Common
    RepoTuple(subscription = 'rhn',
              product = 'rhel',
              product_version = ('1.2', '2.0'),
              role = 'base',
              repoid = 'rhel-x86_64-server-6',
              key_pkg = None),
    RepoTuple(subscription = 'rhn',
              product = 'jboss',
              product_version = ('1.2', '2.0'),
              role = 'node',
              repoid = 'jb-ews-2-x86_64-server-6-rpm',
              key_pkg = 'openshift-origin-cartridge-jbossews'),
    RepoTuple(subscription = 'rhn',
              product = 'jboss',
              product_version = ('1.2', '2.0'),
              role = 'node-eap',
              repoid = 'jbappplatform-6-x86_64-server-6-rpm',
              key_pkg = 'openshift-origin-cartridge-jbosseap'),
]

repositories += [
    # RHN 1.2 repos
    RepoTuple(subscription = 'rhn',
              product = 'ose',
              product_version = '1.2',
              role = 'node',
              repoid = 'rhel-x86_64-server-6-ose-1.2-node',
              key_pkg = 'rubygem-openshift-origin-node'),
    RepoTuple(subscription = 'rhn',
              product = 'ose',
              product_version = '1.2',
              role = 'broker',
              repoid = 'rhel-x86_64-server-6-ose-1.2-infrastructure',
              key_pkg = 'openshift-origin-broker'),
    RepoTuple(subscription = 'rhn',
              product = 'ose',
              product_version = '1.2',
              role = 'client',
              repoid = 'rhel-x86_64-server-6-ose-1.2-rhc',
              key_pkg = 'rhc'),
    RepoTuple(subscription = 'rhn',
              product = 'ose',
              product_version = '1.2',
              role = 'node-eap',
              repoid = 'rhel-x86_64-server-6-ose-1.2-jbosseap',
              key_pkg = 'openshift-origin-cartridge-jbosseap'),
]

repositories += [
    # RHN 2.0 repos
    RepoTuple(subscription = 'rhn',
              product = 'ose',
              product_version = '2.0',
              role = 'node',
              repoid = 'rhel-x86_64-server-6-ose-2.0-node',
              key_pkg = 'rubygem-openshift-origin-node'),
    RepoTuple(subscription = 'rhn',
              product = 'ose',
              product_version = '2.0',
              role = 'broker',
              repoid = 'rhel-x86_64-server-6-ose-2.0-infrastructure',
              key_pkg = 'openshift-origin-broker'),
    RepoTuple(subscription = 'rhn',
              product = 'ose',
              product_version = '2.0',
              role = 'client',
              repoid = 'rhel-x86_64-server-6-ose-2.0-rhc',
              key_pkg = 'rhc'),
    RepoTuple(subscription = 'rhn',
              product = 'ose',
              product_version = '2.0',
              role = 'node-eap',
              repoid = 'rhel-x86_64-server-6-ose-2.0-jbosseap',
              key_pkg = 'openshift-origin-cartridge-jbosseap'),
]

repo_cache = {}

def _repo_tuple_match(repo, match_attr, match_val):
    # Could do this on one line, but this is more readable
    attr = getattr(repo, match_attr, None)
    if match_val == attr:
        return True
    return hasattr(attr, '__iter__') and match_val in attr

def find_repos(**kwargs):
    global repo_cache
    if len(repo_cache) > 512:
        # Try to keep the repo_cache from growing infinitely
        # (Guessing 512 is too big is cheaper than calculating the actual mem footprint)
        repo_cache = {}
    hkey = tuple(sorted(kwargs.items()))
    if None == repo_cache.get(hkey, None):
        repos = copy(repositories)
        for kk, vv in kwargs.items():
            # print kk, vv
            repos = [repo for repo in repos if _repo_tuple_match(repo, kk, vv)]
            # print repos
            if not repos:
                break
        repos = tuple(repos)
        repo_cache[hkey] = repos
        return repos
    return repo_cache[hkey]

def find_repoids(**kwargs):
    return [repo.repoid for repo in find_repos(**kwargs)]

def find_repos_by_repoid(repoids):
    if hasattr(repoids, '__iter__'):
        res = []
        for r_id in repoids:
            res += find_repos(repoid = r_id)
        return tuple(set(res)) # make unique
    return find_repos(repoid = repoids)

if __name__ == '__main__':
    print "find_repos(subscription = 'rhsm'):"
    for xx in find_repos(subscription = 'rhsm'):
        print xx
    print ""
    print "find_repos(product_version = '1.2'):"
    for xx in find_repos(product_version = '1.2'):
        print xx
    print ""
    print "find_repos(product_version = '1.2', role = 'node'):"
    for xx in find_repos(product_version = '1.2', role = 'node'):
        print xx
    print ""
    print "find_repos_by_repoid('rhel-x86_64-server-6-ose-2.0-infrastructure'):"
    for xx in find_repos_by_repoid('rhel-x86_64-server-6-ose-2.0-infrastructure'):
        print xx
    print ""
    print "find_repos_by_repoid(['rhel-x86_64-server-6-ose-2.0-infrastructure', 'jbappplatform-6-x86_64-server-6-rpm']):"
    for xx in find_repos_by_repoid(['rhel-x86_64-server-6-ose-2.0-infrastructure', 'jbappplatform-6-x86_64-server-6-rpm']):
        print xx
    print ""
    print "find_repoids(subscription = 'rhn', role = 'node-eap', product_version = '1.2'):"
    for xx in find_repoids(subscription = 'rhn', role = 'node-eap', product_version = '1.2'):
        print xx
