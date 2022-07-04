# ansible-homelab
All the Ansible playbooks for my homelab.

More information about these playbooks can be found on my blog at https://tizutech.com!

#### Adapted from the starting Ansible playbook of TiZuTech.

# Usage Examples
ansible-playbook playbooks/linux_apt-upgrade.yml -i inventory -kK --limit "linux"

ansible-playbook playbooks/bootstrap/bootstrap.yml -K --limit "setup"

* --limit of course is optional...

# Requirements
* The directory of ansible-homelab should contain an inventory file. 
