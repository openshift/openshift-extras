import subprocess
import os
import yaml

def set_config(cfg):
    global CFG
    CFG = cfg

def generate_inventory(masters, nodes):
    global CFG
    ansible_inventory_directory = CFG.settings['ansible_inventory_directory']
    base_inventory_path = CFG.settings['ansible_inventory_path']
    base_inventory = open(base_inventory_path, 'w')
    base_inventory.write('\n[OSEv3:children]\nmasters\nnodes\n')
    base_inventory.write('\n[OSEv3:vars]\n')
    base_inventory.write('ansible_ssh_user={}\n'.format(CFG.settings['ansible_ssh_user']))
    base_inventory.write('deployment_type={}\n'.format(CFG.deployment_type))
    base_inventory.write('oreg_url=docker-buildvm-rhose.usersys.redhat.com:5000/openshift3/ose-${component}:${version}\n')
    base_inventory.write("openshift_additional_repos=[{'id': 'ose-devel', 'name': 'ose-devel', 'baseurl': 'http://buildvm-devops.usersys.redhat.com/puddle/build/OpenShiftEnterprise/3.0/latest/RH7-RHOSE-3.0/$basearch/os', 'enabled': 1, 'gpgcheck': 0}]\n")
    base_inventory.write('\n[masters]\n')
    for h in masters:
        write_host(h, base_inventory)
    base_inventory.write('\n[nodes]\n')
    for h in nodes:
        write_host(h, base_inventory)
    base_inventory.close()
    return base_inventory_path

def write_host(host, inventory):
    global CFG
    if 'validated_facts' in CFG.settings and host in CFG.settings['validated_facts']:
        ip = CFG.settings['validated_facts'][host]["ip"]
        public_ip = CFG.settings['validated_facts'][host]["public_ip"]
        hostname = CFG.settings['validated_facts'][host]["hostname"]
        public_hostname = CFG.settings['validated_facts'][host]["public_hostname"]
        inventory.write('{} ip={} public_ip={} hostname={} public_hostname={}\n'.format(host, ip, public_ip, hostname, public_hostname))
    else:
        inventory.write('{}\n'.format(host))
    return

def default_facts(masters, nodes):
    global CFG
    # TODO: This is a hack.  This ensures no previously validated_facts can
    # interfere with fetching the facts.
    if 'validated_facts' in CFG.settings:
        del CFG.settings['validated_facts']
    inventory_file = generate_inventory(masters, nodes)
    os_facts_path = '{}/playbooks/byo/openshift_facts.yml'.format(CFG.ansible_playbook_directory)

    facts_env = os.environ.copy()
    facts_env["OO_INSTALL_CALLBACK_FACTS_YAML"] = CFG.settings['ansible_callback_facts_yaml']
    facts_env["ANSIBLE_CALLBACK_PLUGINS"] = CFG.settings['ansible_plugins_directory']
    subprocess.call(['ansible-playbook',
                     '--user={}'.format(CFG.settings['ansible_ssh_user']),
                     '--inventory-file={}'.format(inventory_file),
                     os_facts_path],
                     env=facts_env)
    callback_facts_file = open(CFG.settings['ansible_callback_facts_yaml'], 'r')
    callback_facts = yaml.load(callback_facts_file)
    callback_facts_file.close()
    return callback_facts

def run_main_playbook(masters, nodes):
    global CFG
    inventory_file = generate_inventory(masters, nodes)
    main_playbook_path = '{}/playbooks/byo/config.yml'.format(CFG.ansible_playbook_directory)
    subprocess.call(['ansible-playbook',
                     '--user={}'.format(CFG.settings['ansible_ssh_user']),
                     '--inventory-file={}'.format(inventory_file),
                     main_playbook_path])
    return
