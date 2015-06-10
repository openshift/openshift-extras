import click
import re
import install_transactions

# Shamelessly stolen from http://stackoverflow.com/a/2532344
def is_valid_hostname(hostname):
    if len(hostname) > 255:
        return False
    if hostname[-1] == ".":
        hostname = hostname[:-1] # strip exactly one dot from the right, if present
    allowed = re.compile("(?!-)[A-Z\d-]{1,63}(?<!-)$", re.IGNORECASE)
    return all(allowed.match(x) for x in hostname.split("."))

def validate_hostname(hostname):
    if '' == hostname or is_valid_hostname(hostname):
        return hostname
    raise click.BadParameter('"{}" appears to be an invalid hostname. Please double-check this value and re-enter it.'.format(hostname))

def get_hosts(hosts):
    click.echo('Please input each target host, followed by the return key. When finished, simply press return on an empty line.')
    while True:
        hostname = click.prompt('hostname/IP address', default='', value_proc=validate_hostname)
        if '' == hostname:
            break
        hosts.append(hostname)
    hosts = list(set(hosts)) # uniquify
    return hosts

def list_hosts(hosts):
    hosts_idx = range(len(hosts))
    for idx in hosts_idx:
        click.echo('   {}: {}'.format(idx, hosts[idx]))

def delete_hosts(hosts):
    while True:
        list_hosts(hosts)
        del_idx = click.prompt('Select host to delete or none', type=int, default='')
        if '' == del_idx:
            break
        try:
            hosts.remove(hosts[del_idx])
        except IndexError:
            click.echo("\"{}\" doesn't match any hosts listed.".format(del_idx))
    return hosts

class CLIInstaller:
    def __init__(self):
        self.hosts = []

    def collect_hosts(self):
        while True:
            get_hosts(self.hosts)
            delete_hosts(self.hosts)
            list_hosts(self.hosts)
            if click.confirm('Please validate that the listed hostnames are correct'):
                break

    def main(self):
        self.collect_hosts()
        install_transactions.default_facts(self.hosts)


def main():
    cli_installer = CLIInstaller()
    cli_installer.main()

if __name__ == '__main__':
    main()
