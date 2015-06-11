import subprocess

def set_ansible_dir(ansible_dir):
    global ANSIBLE_DIR
    ANSIBLE_DIR = ansible_dir

def default_facts(hosts):
    global ANSIBLE_DIR
    base_inventory_path = '{}/base_inventory'.format(ANSIBLE_DIR)
    os_facts_path = '{}/playbooks/byo/openshift_facts.yml'.format(ANSIBLE_DIR)
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

