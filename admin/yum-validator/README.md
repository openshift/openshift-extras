# check-sources

This directory contains python libraries and tools for examining and repairing Yum repositories on a given system. In particular, `oo-admin-yum-validator` is designed to validate repository priorities and availability, with the goal of ensuring that OpenShift Enterprise (and later Origin) dependencies aren't overwritten by untested/unsupported versions of the same packages from other repositories.

## Installation

Right now, none as such.

Make sure that this directory is in your load path for Python, either by setting `PYTHONPATH`, modifying `sys.path`, or other methods.

## Usage

### oo-admin-yum-validator

    usage: oo-admin-yum-validator [-h] [-r {node,broker,client,node-eap}]
                                  [-o OO_VERSION] [-s {rhsm,yum,rhn}] [-f] [-a]
                                  [-p] [-c REPO_CONFIG]
    
    optional arguments:
      -h, --help            show this help message and exit
      -r {node,broker,client,node-eap}, --role {node,broker,client,node-eap}
                            OpenShift component role(s) this system will fulfill.
      -o OO_VERSION, --oo_version OO_VERSION, --oo-version OO_VERSION
                            Version of OpenShift in use on this system.
      -s {rhsm,yum,rhn}, --subscription-type {rhsm,yum,rhn}
                            Subscription management system which provides the
                            OpenShift repositories/channels.
      -f, --fix             Attempt to repair the first problem found.
      -a, --fix-all         Attempt to repair all problems found.
      -p, --report-all      Report all problems (default is to halt after first
                            problem report.)
      -c REPO_CONFIG, --repo-config REPO_CONFIG
                            Load blessed repository data from the specified file
                            instead of built-in values

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request
