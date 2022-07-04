# ansible-homelab
All the Ansible playbooks for my homelab.

More information about these playbooks can be found on my blog at https://tizutech.com!

## Adapted from the starting Ansible playbook of TiZuTech.

# Usage Examples
ansible-playbook playbooks/linux_apt-upgrade.yml --ask-become

ansible-playbook playbooks/bootstrap/bootstrap.yml -K --limit "setup"

# Requirements
* The directory of ansible-homelab should contain an inventory file. 
