#!/usr/bin/python -S
#
# This module converts local-only settings for RHSM-managed
# repositories into persistent content overrides (i.e. repo-override)
#
# Lots of bits will probably be^H^H^H^H^H^H^H^H^H are lifted straight
# from the subscription-manager source.

import sys

_LIBPATH = "/usr/share/rhsm"
# add to the path if need be
if _LIBPATH not in sys.path:
    sys.path.append(_LIBPATH)

# this has to be done first thing due to module level translated vars.
from subscription_manager.i18n import configure_i18n
configure_i18n()

from subscription_manager.injectioninit import init_dep_injection
init_dep_injection()

import rhsm.config
from yum import config
from yum.config import RepoConf
from subscription_manager import injection as inj
from subscription_manager.identity import ConsumerIdentity

from collections import defaultdict

IMPORTANT_ATTRS = ['exclude', 'priority', 'enabled']

SET_OVERRIDE_MSG = (
    "Local repository settings have been detected which don't appear in the "
    "Red Hat Subscription Manager content overrides and differ from the "
    "default settings." )
SET_OVERRIDE_REPORT_MSG = (
    "This might not cause any problems, but it is recommended that you persist "
    "these settings as content overrides by running the following commands:" )
SET_OVERRIDE_FIX_MSG = (
    "Updating content overrides:")

def _read(file_path):
    fd = open(file_path, "r")
    file_content = fd.read()
    fd.close()
    return file_content

class SubscriptionManagerNotRegisteredError(Exception):
    """The subscription key or certificate couldn't be found - the system
    is probably not registered
    """
    pass

class ReconciliationEngine(object):
    def __init__(self, oscs, rdb, logger, opts):
        self.oscs = oscs
        self.rdb = rdb
        self.logger = logger
        self.opts = opts
        self.rhsmconfig = rhsm.config.initConfig()
        try:
            self.consumer_key = _read(ConsumerIdentity.keypath())
            self.consumer_cert = _read(ConsumerIdentity.certpath())
        except IOError as ioerr:
            if 2 == ioerr.errno:
                raise SubscriptionManagerNotRegisteredError()
        self.consumer_identity = ConsumerIdentity(self.consumer_key, self.consumer_cert)
        self.consumer_uuid = self.consumer_identity.getConsumerId()
        self.cp_provider = inj.require(inj.CP_PROVIDER)
        self.cp = self.cp_provider.get_consumer_auth_cp()
        # self.ATTR_DEFAULTS = dict([(attr, RepoConf.optionobj(attr).default) for attr in IMPORTANT_ATTRS])
        self._set_attr_defaults()
        self.problem = False

    def _set_attr_defaults(self):
        self.ATTR_DEFAULTS = dict()
        for attr in IMPORTANT_ATTRS:
            try:
                self.ATTR_DEFAULTS[attr] = RepoConf.optionobj(attr).default
            except KeyError:
                IMPORTANT_ATTRS.remove(attr)

    def get_overrides_and_repos(self):
        overrides = self.cp.getContentOverrides(self.consumer_uuid)
        override_repos = list(set([ovrd['contentLabel'] for ovrd in overrides]))
        ovrdict = defaultdict(lambda: defaultdict(lambda: None))
        for ovrd in overrides:
            ovrdict[ovrd['contentLabel']][ovrd['name']] = ovrd['value']
        return ovrdict, override_repos

    def set_override(self, repo, attr):
        if not self.problem:
            self.logger.error(SET_OVERRIDE_MSG)
            if self.opts.fix:
                self.logger.error(SET_OVERRIDE_FIX_MSG)
            else:
                self.logger.error(SET_OVERRIDE_REPORT_MSG)
        self.problem = True
        value = repo.getAttribute(attr)
        option = RepoConf.optionobj(attr)
        if self.opts.fix:
            if isinstance(option, config.ListOption):
                v_str = ' '.join(value)
            else:
                v_str = option.tostring(value)
            if self.current_repoid != repo.id:
                self.current_repoid = repo.id
                self.logger.error("Updating repository %s" % repo.id)
            self.logger.error("    %s: %s" % (attr, v_str))
            self.oscs.set_save_repo_attr(repo.id, attr, value)
        else:
            self.logger.error(
                "# %s" %
                self.oscs.get_update_override_cmd(
                    repo, attr, repo.getAttribute(attr), for_output=True))

    def fix_overrides_for_repo(self, repoid, overrides):
        self.current_repoid=""
        try:
            repo = self.oscs.repo_for_repoid(repoid)
        except KeyError:
            if self.opts.fix:
                self.logger.warning('Cannot modify content overrides for '
                                    'non-existent repo %s' % repoid)
            return # don't operate on nonexistant repos
        for attr in IMPORTANT_ATTRS:
            if repo.getAttribute(attr) != self.ATTR_DEFAULTS[attr]:
                if not overrides[repoid] or not overrides[repoid][attr]:
                    self.set_override(repo, attr)

    def reconcile_overrides(self):
        (overrides, override_repos) = self.get_overrides_and_repos()
        rhsm_repoids = self.rdb.find_repoids(subscription = 'rhsm')
        for repoid in rhsm_repoids:
            self.fix_overrides_for_repo(repoid, overrides)
        return self.problem

if __name__ == '__main__':
    from yumvalidator.check_sources import CheckSources
    from yumvalidator.repo_db import RepoDB
    import logging
    logger = logging.getLogger()
    logger.setLevel(logging.INFO)
    opts = lambda: None
    setattr(opts, 'fix', False)
    re = ReconciliationEngine(CheckSources(), RepoDB(), logger, opts)
    re.reconcile_overrides()
