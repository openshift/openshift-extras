import subprocess

def set_config(cfg):
    global CFG
    CFG = cfg

def default_facts(hosts):
    global CFG
    ansible_inventory_directory = CFG.settings['ansible_inventory_directory']
    base_inventory_path = '{}/hosts'.format(ansible_inventory_directory)
    os_facts_path = '{}/playbooks/byo/openshift_facts.yml'.format(CFG.ansible_playbook_directory)
    base_inventory = open(base_inventory_path, 'w')
    base_inventory.write('# This is the base inventory used for obtaining \n'
                         '# default facts from target systems\n')
    for hostname in hosts:
        base_inventory.write('{}\n'.format(hostname))
    base_inventory.close()
    subprocess.call(['ansible-playbook',
                     '--user=root',
                     '--inventory-file={}'.format(base_inventory_path),
                     os_facts_path])

