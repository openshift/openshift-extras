import os
import yaml
from tempfile import mkstemp

class CallbackModule(object):
    """
    """

    def __init__(self):
        ######################
        # This is ugly stoopid. This should be updated in the following ways:
        # 1) it should output host data to predictable files, e.g. $OO_ANSIBLE_DIRECTORY/host_data/hostname.yml
        # 2) it should only output the host data looked for (e.g. there should be far fewer .writes below
        # 3) it should probably only be used for the openshift_facts.yml playbook, so maybe there's some way to check a variable that's set when that playbook is run?
        self.outfile, self.outfile_name = mkstemp()
        print 'outfile_name = {}'.format(self.outfile_name)

    def on_any(self, *args, **kwargs):
        pass

    def runner_on_failed(self, host, res, ignore_errors=False):
        os.write(self.outfile, ('RUNNER_ON_FAILED ' + host + ' ' + yaml.safe_dump(res)))

    def runner_on_ok(self, host, res):
        os.write(self.outfile, ('RUNNER_ON_OK ' + host + ' ' + yaml.safe_dump(res)))

    def runner_on_skipped(self, host, item=None):
        os.write(self.outfile, ('RUNNER_ON_SKIPPED ' + host + ' ...'))

    def runner_on_unreachable(self, host, res):
        os.write(self.outfile, ('RUNNER_UNREACHABLE ' + host + ' ' + yaml.safe_dump(res)))

    def runner_on_no_hosts(self):
        pass

    def runner_on_async_poll(self, host, res):
        pass

    def runner_on_async_ok(self, host, res):
        pass

    def runner_on_async_failed(self, host, res):
        os.write(self.outfile, ('RUNNER_SYNC_FAILED ' + host + ' ' + yaml.safe_dump(res)))

    def playbook_on_start(self):
        pass

    def playbook_on_notify(self, host, handler):
        pass

    def playbook_on_no_hosts_matched(self):
        pass

    def playbook_on_no_hosts_remaining(self):
        pass

    def playbook_on_task_start(self, name, is_conditional):
        pass

    def playbook_on_vars_prompt(self, varname, private=True, prompt=None, encrypt=None, confirm=False, salt_size=None, salt=None, default=None):
        pass

    def playbook_on_setup(self):
        pass

    def playbook_on_import_for_host(self, host, imported_file):
        os.write(self.outfile, ('PLAYBOOK_ON_IMPORTED ' + host + ' ' + yaml.safe_dump(res)))

    def playbook_on_not_import_for_host(self, host, missing_file):
        os.write(self.outfile, ('PLAYBOOK_ON_NOTIMPORTED ' + host + ' ' + yaml.safe_dump(res)))

    def playbook_on_play_start(self, name):
        pass

    def playbook_on_stats(self, stats):
        pass
