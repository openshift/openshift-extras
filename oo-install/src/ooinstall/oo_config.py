import os
import yaml
from pkg_resources import resource_string, resource_filename

PERSIST_SETTINGS=[
    'Description',
    'Name',
    'Subscription',
    'Vendor',
    'Version',
    'masters',
    'nodes',
    'ansible_config',
    ]

class OOConfigFileError(Exception):
    """The provided config file path can't be read/written
    """
    pass

class OOConfig(object):
    settings = {}
    new_config = True
    default_dir = os.path.normpath(
        os.environ.get('XDG_CONFIG_HOME',
                       os.environ['HOME'] + '/.config/') + '/openshift/')
    default_file = '/installer.cfg.yml'

    def __init__(self, config_path):
        if config_path:
            self.config_path = os.path.normpath(config_path)
        else:
            self.config_path = os.path.normpath(self.default_dir +
                                                self.default_file)
        self.read_config()
        self.set_defaults()

    def set_defaults(self):
        if not 'ansible_config' in self.settings:
            self.settings['ansible_config'] = resource_filename(__name__, 'ansible.cfg')
        # clean up any empty sets
        for setting in self.settings.keys():
            if not self.settings[setting]:
                self.settings.pop(setting)

    def read_config(self, is_new = False):
        try:
            new_settings = None
            if os.path.exists(self.config_path):
                cfgfile = open(self.config_path, 'r')
                new_settings = yaml.safe_load(cfgfile.read())
            if new_settings:
                self.settings = new_settings
            else:
                self.install_default()
        except IOError, ferr:
            raise OOConfigFileError('Cannot open config file "{}": {}'.format(ferr.filename, ferr.strerror))
        except yaml.scanner.ScannerError:
            raise OOConfigFileError('Config file "{}" is not a valid YAML document'.format(self.config_path))
        self.new_config = is_new

    def save_to_disk(self):
        out_file = open(self.config_path, 'w')
        out_file.write(self.yaml())
        out_file.close()

    def persist_settings(self):
        p_settings = {}
        for setting in PERSIST_SETTINGS:
            if setting in self.settings and self.settings[setting]:
                p_settings[setting] = self.settings[setting]
        return p_settings

    def yaml(self):
        return yaml.safe_dump(self.persist_settings())

    def __str__(self):
        return self.yaml()

    def install_default(self):
        config_template = resource_string(__name__, 'installer.cfg.template.yml')
        cfg_dir, cfg_file = os.path.split(self.config_path)
        if not os.path.exists(cfg_dir):
            os.makedirs(cfg_dir)
        out_file = open(self.config_path, 'w')
        out_file.write(config_template)
        self.settings = yaml.safe_load(config_template)
        out_file.close()
