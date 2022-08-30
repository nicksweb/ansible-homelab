# ansible-homelab
All the Ansible playbooks for my homelab.

More information about these playbooks can be found on my blog at https://tizutech.com!

#### Adapted from the starting Ansible playbook of TiZuTech.

# Usage Examples
* Run APT Update / Upgrade on Inventory - ansible-playbook playbooks/linux_apt-upgrade.yml -i inventory -kK --limit "linux"
* Boostrap for the SA Network - ansible-playbook playbooks/bootstrap/bootstrap.yml -K --limit "setup"
* Run a Speedtest if speedtest-cli is installed - ansible-playbook -i inventory playbooks/speedtest.yml -l 172.16.0.23 -kK
* Prepare a Docker Host - ansible-playbook playbooks/docker.yml -i inventory --limit 172.16.0.207 -kK
* --limit of course is optional...

## Extended Examples: 

* ansible-playbook playbooks/docker.yml -l 192.168.1.35 -kK -i nbc
* ansible-playbook playbooks/bootstrap.yml -l 172.16.1.223 -kK -i inventory
* ansible-playbook speedtest.yml -i ../inventory -k -l 172.16.0.60

## Installing a Galaxy

* ansible-galaxy install geerlingguy.ntp
* ansible-galaxy install geerlingguy.docker

# Requirements
* The directory of ansible-homelab should contain an inventory file. 
