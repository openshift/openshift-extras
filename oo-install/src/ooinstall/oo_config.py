import os
import yaml

class OOConfigFileError(Exception):
    """The provided config file path can't be read/written
    """
    pass

class OOConfig(object):

    ansible_directory = ''
    hosts = []
    loaded = False

    def __init__(self, config_path):
        self.config_path = config_path
        if os.path.exists(config_path):
            self.read_config()

    def read_config(self):
        try:
            cfgfile = open(self.config_path, 'r')
            params = yaml.safe_load(cfgfile.read())
        except IOError, ferr:
            raise OOConfigFileError('Cannot open config file "{}": {}'.format(ferr.filename, ferr.strerror))
        except yaml.scanner.ScannerError:
            raise OOConfigFileError('Config file "{}" is not a valid YAML document'.format(self.config_path))
        self.ansible_directory = params['ansible_directory']
        self.hosts = params['hosts']
        self.loaded = True

    def yaml(self):
        return yaml.dump(self.__dict__)

    def __str__(self):
        return self.yaml()
