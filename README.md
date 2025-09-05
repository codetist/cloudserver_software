# Hetzner Cloud Servers with Ansible - Software

The [cloudserver](https://github.com/codetist/cloudserver) project
creates the Hetzner vServers and does initial security and config
setup. This project provides the server specific software setup.

## Usage
```
## Install requirement
ansible-galaxy install -r requirements.yml --force

## Run playbooks
ansible-playbook 01_setup_server1.yml

## Use tags
ansible-playbook 01_setup_server1.yml --tags <TAG>
```

## Roles overview

### dnsrecords

- set DNS records via Hetzner API

### fail2ban

- basically rate limiting for authorization requests

### letsencryptnginx

- retrieve and renew Lets Encrypt certificates by using ACME challenge
  through Nginx

### monitoring

- prometheus exporters
- simple bash script to create metrics through Prometheus Pushgateway

### nginx

- nginx and vhosts including GeoIP restrictions

### podman

- podman and containers

### postfix

- postfix, relaying all server internal mails to an external mailbox
  and providing a locally available SMTP server

### simplebackup

- copying and archiving files for backup purposes

## Vaults 

Vaults are not included in this repository. All vault variables are postfixed with `_vault`.
