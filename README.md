# Hermes SSH Access Setup

Secure SSH access for the Hermes AI agent with controlled sudo access on Linux VMs.

## Concept

Hermes needs two different access levels:

1. **Read/debug access**
   - Used for inspection, diagnostics, logs, service status, network state, disk/memory checks.
   - Must work without interruption.
   - Implemented as `NOPASSWD` sudo for a broad but read-oriented command allowlist.

2. **Admin/write access**
   - Used for changes such as service restarts, package operations, editing files, or writing to root-owned paths.
   - Must require explicit user confirmation before execution.
   - Implemented as `NOPASSWD` sudo for a smaller write/admin command allowlist, with confirmation enforced by Hermes before running the tool command.

Important: do **not** rely on an interactive sudo password prompt for Hermes.
An AI agent running through tools cannot reliably enter an interactive sudo password on a remote SSH session. The practical control point is:

- **remote sudo allowlist** controls *what* the `hermes` user may do as root;
- **Hermes approval mode** controls *when* state-changing commands may be executed;
- **sudo logs / journald / auditd** provide accountability.

So the model is not "passwordless root". It is:

> scoped passwordless sudo + explicit agent-side approval for risky commands.

## Recommended Control Model

| Tier | Purpose | sudo authentication | Approval |
|---|---|---:|---|
| Read/debug | Logs, status, network, process, filesystem inspection | `NOPASSWD` | not required |
| Admin/write | Restart services, edit files, package operations, write root-owned files | `NOPASSWD` for allowlisted commands | required in Hermes |

Hermes must **not** run in YOLO mode for this model.

Recommended Hermes setting:

```bash
hermes config set approvals.mode manual
```

`smart` can be used later, but for sysadmin access start with `manual`.

## FreeIPA Setup

These steps assume current FreeIPA 4.x CLI syntax.

### 1. Create the `hermes` user

Run on an enrolled FreeIPA admin host with valid Kerberos credentials.

```bash
kinit admin

ipa user-add hermes \
  --first=Hermes \
  --last=Agent \
  --email=hermes@bitbull.ch \
  --shell=/bin/bash

ipa user-mod hermes \
  --sshpubkey="ssh-ed25519 AAAA... bob@hermes2.sun.bitbull.ch"
```

Verify:

```bash
ipa user-show hermes
```

The user must have a valid home directory and shell. On target systems this should resolve to:

```text
/home/hermes
/bin/bash
```

### 2. Allow sudo through HBAC

FreeIPA HBAC must allow the **Sudo service group**. Adding only the individual `sudo` service is not enough for this setup.

```bash
ipa hbacrule-add "hermes-sudo"
ipa hbacrule-add-user "hermes-sudo" --users=hermes
ipa hbacrule-add-service "hermes-sudo" --hbacsvcgroups=Sudo
```

Apply to all hosts by setting host category to all:

```bash
ipa hbacrule-mod "hermes-sudo" --hostcat=all
```

Verify:

```bash
ipa hbacrule-show "hermes-sudo"
```

Expected relevant output:

```text
Rule name: hermes-sudo
Host category: all
Users: hermes
HBAC Service Groups: Sudo
```

### 3. Create sudo commands

Create command objects. Re-running existing commands may report that they already exist; that is fine.

```bash
# Read/debug commands
for cmd in \
  /usr/bin/journalctl \
  /usr/bin/dmesg \
  /usr/bin/ss \
  /usr/sbin/ss \
  /sbin/ip \
  /usr/bin/systemctl \
  /usr/bin/free \
  /usr/bin/df \
  /usr/bin/du \
  /usr/bin/top \
  /usr/bin/htop \
  /usr/bin/lsof \
  /usr/bin/strace \
  /usr/bin/tail \
  /usr/bin/cat \
  /bin/ls \
  /usr/bin/find \
  /usr/bin/grep \
  /usr/bin/nproc \
  /usr/bin/mount \
  /usr/bin/umount \
  /usr/bin/showmount \
  /usr/bin/ps \
  /usr/bin/w \
  /usr/bin/uptime
 do
  ipa sudocmd-add "$cmd" || true
 done

# Admin/write commands
for cmd in \
  /usr/bin/systemctl \
  /usr/bin/vim \
  /usr/bin/nano \
  /usr/bin/rpm \
  /usr/bin/dnf \
  /usr/bin/tee \
  /usr/bin/install \
  /usr/bin/cp \
  /usr/bin/mv
 do
  ipa sudocmd-add "$cmd" || true
 done
```

Note: `systemctl` appears in both tiers. The command path is the same, but operationally Hermes treats status/read operations differently from restart/reload/enable/disable operations. The sudo layer can only allow commands by path unless you model more restrictive command entries.

### 4. Create read/debug sudo rule

```bash
ipa sudorule-add "hermes-read" \
  --desc="Read/debug sudo for Hermes agent" \
  --hostcat=all

ipa sudorule-add-user "hermes-read" --users=hermes

for cmd in \
  /usr/bin/journalctl \
  /usr/bin/dmesg \
  /usr/bin/ss \
  /usr/sbin/ss \
  /sbin/ip \
  /usr/bin/systemctl \
  /usr/bin/free \
  /usr/bin/df \
  /usr/bin/du \
  /usr/bin/top \
  /usr/bin/htop \
  /usr/bin/lsof \
  /usr/bin/strace \
  /usr/bin/tail \
  /usr/bin/cat \
  /bin/ls \
  /usr/bin/find \
  /usr/bin/grep \
  /usr/bin/nproc \
  /usr/bin/mount \
  /usr/bin/umount \
  /usr/bin/showmount \
  /usr/bin/ps \
  /usr/bin/w \
  /usr/bin/uptime
 do
  ipa sudorule-add-allow-command "hermes-read" --sudocmds="$cmd"
 done

ipa sudorule-add-option "hermes-read" --sudooption='!authenticate'
```

### 5. Create admin/write sudo rule

This rule is also `NOPASSWD`, because Hermes cannot reliably handle an interactive remote sudo password prompt.
The safety boundary is the allowlist plus Hermes approval before execution.

```bash
ipa sudorule-add "hermes-admin" \
  --desc="Admin/write sudo for Hermes agent; requires Hermes approval" \
  --hostcat=all

ipa sudorule-add-user "hermes-admin" --users=hermes

for cmd in \
  /usr/bin/systemctl \
  /usr/bin/vim \
  /usr/bin/nano \
  /usr/bin/rpm \
  /usr/bin/dnf \
  /usr/bin/tee \
  /usr/bin/install \
  /usr/bin/cp \
  /usr/bin/mv
 do
  ipa sudorule-add-allow-command "hermes-admin" --sudocmds="$cmd"
 done

ipa sudorule-add-option "hermes-admin" --sudooption='!authenticate'
```

### 6. Verify FreeIPA rules

```bash
ipa sudorule-show "hermes-read"
ipa sudorule-show "hermes-admin"
ipa hbacrule-show "hermes-sudo"
ipa user-show hermes
```

Expected essentials:

```text
hermes-read:
  Host category: all
  Users: hermes
  Sudo Option: !authenticate

hermes-admin:
  Host category: all
  Users: hermes
  Sudo Option: !authenticate

hermes-sudo:
  Host category: all
  Users: hermes
  HBAC Service Groups: Sudo
```

## FreeIPA Target Host Requirements

On every FreeIPA-joined target VM:

```bash
getent passwd hermes
id hermes
```

Expected:

```text
hermes:x:<uid>:<gid>:Hermes Agent:/home/hermes:/bin/bash
```

The home directory must exist:

```bash
sudo mkdir -p /home/hermes
sudo chown hermes:hermes /home/hermes
sudo chmod 0755 /home/hermes
```

SSSD/sudo integration should be enabled according to your platform baseline. Typical checks:

```bash
sudo sss_cache -E
sudo systemctl restart sssd
sudo -l -U hermes
```

## Standalone Host Setup without FreeIPA

For non-FreeIPA systems such as Alpine, create a local `hermes` user, deploy an SSH key, and install sudoers drop-ins.

### Ansible playbook

Save as `deploy-hermes-ssh-access.yml`.

```yaml
---
- name: Deploy Hermes SSH and sudo access on standalone Linux hosts
  hosts: all
  become: true
  gather_facts: true

  vars:
    hermes_user: hermes
    hermes_comment: Hermes AI Agent
    hermes_home: /home/hermes
    hermes_shell_default: /bin/sh
    hermes_ssh_public_key: "{{ lookup('file', 'files/hermes.pub') }}"

    hermes_read_commands_common:
      - /bin/ls
      - /bin/cat
      - /bin/ps
      - /bin/df
      - /usr/bin/du
      - /usr/bin/find
      - /usr/bin/grep
      - /usr/bin/tail
      - /usr/bin/top
      - /usr/bin/uptime
      - /usr/bin/free
      - /usr/bin/ss
      - /usr/sbin/ss
      - /sbin/ip
      - /usr/bin/journalctl
      - /usr/bin/dmesg
      - /usr/bin/lsof
      - /usr/bin/strace
      - /usr/bin/systemctl
      - /sbin/rc-service
      - /sbin/service

    hermes_admin_commands_common:
      - /usr/bin/systemctl
      - /sbin/rc-service
      - /sbin/service
      - /usr/bin/tee
      - /usr/bin/install
      - /bin/cp
      - /bin/mv
      - /usr/bin/vi
      - /usr/bin/vim
      - /usr/bin/nano
      - /sbin/apk
      - /usr/bin/dnf
      - /usr/bin/rpm

  pre_tasks:
    - name: Install sudo on Alpine
      ansible.builtin.apk:
        name: sudo
        state: present
      when: ansible_facts.os_family == 'Alpine'

    - name: Install sudo on RedHat family
      ansible.builtin.package:
        name: sudo
        state: present
      when: ansible_facts.os_family == 'RedHat'

    - name: Install sudo on Debian family
      ansible.builtin.package:
        name: sudo
        state: present
      when: ansible_facts.os_family == 'Debian'

  tasks:
    - name: Choose shell if bash exists
      ansible.builtin.stat:
        path: /bin/bash
      register: bash_stat

    - name: Create Hermes user
      ansible.builtin.user:
        name: "{{ hermes_user }}"
        comment: "{{ hermes_comment }}"
        home: "{{ hermes_home }}"
        shell: "{{ '/bin/bash' if bash_stat.stat.exists else hermes_shell_default }}"
        create_home: true
        state: present

    - name: Ensure Hermes SSH directory exists
      ansible.builtin.file:
        path: "{{ hermes_home }}/.ssh"
        state: directory
        owner: "{{ hermes_user }}"
        group: "{{ hermes_user }}"
        mode: "0700"

    - name: Install Hermes SSH public key
      ansible.posix.authorized_key:
        user: "{{ hermes_user }}"
        key: "{{ hermes_ssh_public_key }}"
        state: present
        exclusive: false

    - name: Detect existing read commands
      ansible.builtin.stat:
        path: "{{ item }}"
      loop: "{{ hermes_read_commands_common }}"
      register: hermes_read_command_stats

    - name: Detect existing admin commands
      ansible.builtin.stat:
        path: "{{ item }}"
      loop: "{{ hermes_admin_commands_common }}"
      register: hermes_admin_command_stats

    - name: Build read command allowlist
      ansible.builtin.set_fact:
        hermes_read_commands: >-
          {{ hermes_read_command_stats.results
             | selectattr('stat.exists')
             | map(attribute='item')
             | list
             | unique }}

    - name: Build admin command allowlist
      ansible.builtin.set_fact:
        hermes_admin_commands: >-
          {{ hermes_admin_command_stats.results
             | selectattr('stat.exists')
             | map(attribute='item')
             | list
             | unique }}

    - name: Deploy read/debug sudoers rule
      ansible.builtin.copy:
        dest: /etc/sudoers.d/10-hermes-read
        owner: root
        group: root
        mode: "0440"
        validate: "visudo -cf %s"
        content: |
          # Hermes agent read/debug tier - no interactive password.
          {{ hermes_user }} ALL=(root) NOPASSWD: {{ hermes_read_commands | join(', ') }}

    - name: Deploy admin/write sudoers rule
      ansible.builtin.copy:
        dest: /etc/sudoers.d/20-hermes-admin
        owner: root
        group: root
        mode: "0440"
        validate: "visudo -cf %s"
        content: |
          # Hermes agent admin/write tier.
          # Commands are passwordless because confirmation is enforced by Hermes before execution.
          {{ hermes_user }} ALL=(root) NOPASSWD: {{ hermes_admin_commands | join(', ') }}
```

### Example inventory

```ini
[standalone]
alpine01.example.net
edge01.example.net
```

### Run

```bash
ansible-playbook -i inventory.ini deploy-hermes-ssh-access.yml
```

## Verification

### SSH access

```bash
ssh hermes@graylog1.sun.bitbull.ch 'whoami; id; hostname -f'
```

### Read/debug tier

Should work without a password:

```bash
ssh hermes@graylog1.sun.bitbull.ch 'sudo -n journalctl --no-pager -n 3'
ssh hermes@graylog1.sun.bitbull.ch 'sudo -n ss -tlnp'
ssh hermes@graylog1.sun.bitbull.ch 'sudo -n df -h'
```

### Admin/write tier

This should also work without a remote sudo password, but Hermes should ask for confirmation before executing the local tool command if the command is state-changing.

Example test:

```bash
ssh hermes@graylog1.sun.bitbull.ch 'date | sudo tee /root/access_test.log'
ssh hermes@graylog1.sun.bitbull.ch 'sudo cat /root/access_test.log'
```

Expected:

- file `/root/access_test.log` exists;
- content is the current date from the test run;
- sudo log records `hermes` executing `tee` and `cat`.

### Sudo listing on target

```bash
ssh hermes@graylog1.sun.bitbull.ch 'sudo -l'
```

Expected entries include:

```text
(root) NOPASSWD: ...read/debug commands...
(root) NOPASSWD: ...admin/write commands...
```

## Operational Notes

- Keep the sudo command lists scoped. Do not grant unrestricted `ALL` unless this is a deliberately trusted lab host.
- Prefer command-specific workflows from Hermes: `tee`, `install`, `systemctl restart <unit>`, package manager commands, etc.
- Keep Hermes approval mode enabled for sysadmin environments.
- Log review remains host-native: sudo logs, journald, auditd, Graylog/Wazuh forwarding.
- For stricter separation, create two Hermes identities later, e.g. `hermes-read` and `hermes-admin`, each with different SSH keys and sudo rules.

## Summary

This setup gives Hermes practical sysadmin access without pretending an interactive sudo password prompt is a useful approval mechanism for an AI agent:

- broad read/debug sudo for fast diagnostics;
- narrow admin/write sudo allowlist;
- no remote interactive sudo password dependency;
- user confirmation enforced by Hermes before state-changing tool calls;
- complete auditability through SSH and sudo logs.
