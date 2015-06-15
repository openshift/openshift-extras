import subprocess

def set_config(cfg):
    global CFG
    CFG = cfg

def default_facts(masters, nodes):
    global CFG
    ansible_inventory_directory = CFG.settings['ansible_inventory_directory']
    base_inventory_path = '{}/hosts'.format(ansible_inventory_directory)
    os_facts_path = '{}/playbooks/byo/openshift_facts.yml'.format(CFG.ansible_playbook_directory)
    base_inventory = open(base_inventory_path, 'w')
    base_inventory.write('# This is the base inventory used for obtaining \n'
                         '# default facts from target systems\n')
    base_inventory.write('\n[masters]')
    for hostname in masters:
        base_inventory.write('{}\n'.format(hostname))

    base_inventory.write('\n[nodes]')
    for hostname in nodes:
        base_inventory.write('{}\n'.format(hostname))
    base_inventory.close()
    subprocess.call(['ansible-playbook',
                     '--user=root',
                     '--inventory-file={}'.format(base_inventory_path),
                     os_facts_path])

def generate_default_master_vars(masters):
    global CFG
    ansible_inventory_directory = CFG.settings['ansible_inventory_directory']
    return
