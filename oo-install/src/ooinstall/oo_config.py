import os
import yaml
from pkg_resources import resource_string

class OOConfigFileError(Exception):
    """The provided config file path can't be read/written
    """
    pass

class OOConfig(object):

    # ansible_directory = ''
    # hosts = []
    settings = {}
    new_config = True
    # default_dir = os.environ['HOME'] + '/.openshift/'
    default_dir = os.path.normpath(
        os.environ.get('XDG_CONFIG_HOME',
                       os.environ['HOME'] + '/.config/') + '/openshift/')
    default_file = '/installer.cfg.yml'
    config_template = resource_string(__name__, 'installer.cfg.template.yml')
    
    def __init__(self, config_path):
        if config_path:
            self.config_path = config_path
        else:
            self.config_path = self.default_dir + self.default_file
        print 'self.config_path: {}'.format(self.config_path)
        if os.path.exists(self.config_path):
            self.read_config()
        # else:
        #     self.install_default(config_path)

    def read_config(self):
        try:
            cfgfile = open(self.config_path, 'r')
            self.settings = yaml.safe_load(cfgfile.read())
        except IOError, ferr:
            raise OOConfigFileError('Cannot open config file "{}": {}'.format(ferr.filename, ferr.strerror))
        except yaml.scanner.ScannerError:
            raise OOConfigFileError('Config file "{}" is not a valid YAML document'.format(self.config_path))
        self.new_config = False

    def yaml(self):
        return yaml.dump(self.settings)

    def __str__(self):
        return self.yaml()
