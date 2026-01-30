# Ansible Deployment

Ansible playbooks that manage the same Docker Compose stack. Use this
when you need to deploy to remote hosts, integrate with existing Ansible
inventories, or want built-in health-check retries.

## Prerequisites

- Ansible >= 2.12
- `community.docker` collection: `ansible-galaxy collection install community.docker`
- Docker running on target host(s)

## Usage

```bash
cd ansible

# Deploy
ansible-playbook -i inventory.yml deploy.yml

# Generate load
ansible-playbook -i inventory.yml generate-load.yml -e duration=120

# Tear down
ansible-playbook -i inventory.yml teardown.yml
```

## Remote hosts

Edit `inventory.yml` to target remote Docker hosts:

```yaml
all:
  hosts:
    staging-server:
      ansible_host: 10.0.1.50
      ansible_user: deploy
```

Ensure the project directory is synced to the remote host (via rsync,
git clone, or an additional playbook task).
