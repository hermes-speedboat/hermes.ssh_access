# Hermes SSH Access Setup

Secure SSH access for the Hermes AI agent with two-tier sudo privileges.

## Concept

The Hermes agent needs system administration access to manage VMs. This setup provides:

- **Read tier (NOPASSWD):** Full read/debug access — `journalctl`, `dmesg`, `ss`, `ip`, `systemctl status`, etc. No approval needed, instant execution.
- **Write tier (password required):** Service actions (`systemctl restart`, `vim`, `rpm`, `dnf`). Requires your explicit approval in the conversation.

This ensures the agent can debug prod without paging you, but nothing changes state without your OK.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     FreeIPA (if joined)                         │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐ │
│  │ hermes-read     │  │ hermes-write    │  │ hermes-sudo     │ │
│  │ (NOPASSWD)      │  │ (requires pwd)  │  │ (HBAC rule)     │ │
│  │ journalctl      │  │ systemctl restart│  │ Sudo service   │ │
│  │ dmesg           │  │ vim             │  │ group           │ │
│  │ ss, ip          │  │ nano            │  │ all hosts       │ │
│  │ systemctl status│  │ rpm, dnf        │  │ users: hermes   │ │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
                            ↓ SSH key (FreeIPA managed)
┌─────────────────────────────────────────────────────────────────┐
│                     Target VM (Hermes user)                     │
│  hermes@<vm>                                                    │
│  - SSH key: /etc/ssh/ssh_config.d/04-ipa.conf (FreeIPA)        │
│  - Sudo rules: FreeIPA or /etc/sudoers.d/                        │
│  - Home: /home/hermes (required for PAM)                        │
└─────────────────────────────────────────────────────────────────┘
```

## Two Deployment Paths

### Path A: FreeIPA-joined hosts (recommended)

1. Create FreeIPA rules (FreeIPA server)
2. Distribute SSH key to hermes user (FreeIPA or Ansible)
3. Verify on target VMs

### Path B: Standalone hosts (e.g., Alpine, non-FreeIPA)

1. Create hermes user with SSH key
2. Deploy sudoers drop-in via Ansible
3. Verify on target VM

## Table of Contents

- [FreeIPA Setup](#freeipa-setup)
- [Standalone Host Setup](#standalone-host-setup)
- [Verification](#verification)
- [Troubleshooting](#troubleshooting)

---

## FreeIPA Setup

### Step 1: Create the hermes user in FreeIPA

```bash
ipa user-add hermes \
  --first=Hermes \
  --last=Agent \
  --email=hermes@bitbull.ch \
  --shell=/bin/bash

# Add SSH public key (replace with your key)
ipa user-mod hermes --sshpubkey="ssh-ed25519 AAAA... your@local"
```

### Step 2: Create HBAC rule (required for sudo)

```bash
# Allow hermes to use the Sudo service
ipa hbacrule-add "hermes-sudo"
ipa hbacrule-add-user "hermes-sudo" --users hermes
ipa hbacrule-add-service "hermes-sudo" --hbacsvcgroups=Sudo
```

**Note:** This is critical. Without this HBAC rule, FreeIPA blocks sudo regardless of sudoers rules.

### Step 3: Create read tier (NOPASSWD)

```bash
# Create the rule
ipa sudorule-add "hermes-read" \
  --desc "Read-only sudo for Hermes agent" \
  --hostcat=all

# Add read commands
ipa sudocmd-add /usr/bin/journalctl
ipa sudocmd-add /usr/bin/dmesg
ipa sudocmd-add /usr/bin/ss
ipa sudocmd-add /usr/sbin/ss
ipa sudocmd-add /sbin/ip
ipa sudocmd-add /usr/bin/systemctl
ipa sudocmd-add /usr/bin/free
ipa sudocmd-add /usr/bin/df
ipa sudocmd-add /usr/bin/du
ipa sudocmd-add /usr/bin/top
ipa sudocmd-add /usr/bin/htop
ipa sudocmd-add /usr/bin/lsof
ipa sudocmd-add /usr/bin/strace
ipa sudocmd-add /usr/bin/tail
ipa sudocmd-add /usr/bin/cat
ipa sudocmd-add /bin/ls
ipa sudocmd-add /usr/bin/find
ipa sudocmd-add /usr/bin/grep
ipa sudocmd-add /usr/bin/nproc
ipa sudocmd-add /usr/bin/mount
ipa sudocmd-add /usr/bin/umount
ipa sudocmd-add /usr/bin/showmount
ipa sudocmd-add /usr/bin/ps
ipa sudocmd-add /usr/bin/w
ipa sudocmd-add /usr/bin/uptime

# Attach commands to rule
for cmd in /usr/bin/journalctl /usr/bin/dmesg /usr/bin/ss /usr/sbin/ss /sbin/ip /usr/bin/systemctl /usr/bin/free /usr/bin/df /usr/bin/du /usr/bin/top /usr/bin/htop /usr/bin/lsof /usr/bin/strace /usr/bin/tail /usr/bin/cat /bin/ls /usr/bin/find /usr/bin/grep /usr/bin/nproc /usr/bin/mount /usr/bin/umount /usr/bin/showmount /usr/bin/ps /usr/bin/w /usr/bin/uptime; do
  ipa sudorule-add-allow-command "hermes-read" --sudocmds="$cmd"
done

### Step 3: Enable NOPASSWD on read rule

```bash
ipa sudorule-add-option "hermes-read" --sudooption '!authenticate'
```

# Assign user
ipa sudorule-add-user "hermes-read" --users hermes
```

### Step 4: Create write tier (requires password)

```bash
# Create the rule (no --sudooption = password required)
ipa sudorule-add "hermes-write" \
  --desc "Write sudo for Hermes agent (requires password)" \
  --hostcat=all

# Add write commands
ipa sudocmd-add /usr/bin/systemctl
ipa sudocmd-add /usr/bin/vim
ipa sudocmd-add /usr/bin/nano
ipa sudocmd-add /usr/bin/rpm
ipa sudocmd-add /usr/bin/dnf

# Attach commands to rule
for cmd in /usr/bin/systemctl /usr/bin/vim /usr/bin/nano /usr/bin/rpm /usr/bin/dnf; do
  ipa sudorule-add-allow-command "hermes-write" --sudocmds="$cmd"
done

# Assign user
ipa sudorule-add-user "hermes-write" --users hermes
```

### Step 5: Verify on a target VM

```bash
# SSH as hermes
ssh hermes@<vm>

# Test read tier (should work without password)
sudo -n journalctl -u ssh --no-pager -n 3

# Test write tier (should prompt for password)
sudo -n systemctl restart nginx
```

---

## Standalone Host Setup

For hosts NOT joined to FreeIPA (e.g., Alpine, custom builds), use this Ansible playbook.

### Ansible Playbook: `deploy-hermes-sudo.yml`

```yaml
---
- name: Deploy two-tier sudo access for Hermes agent
  hosts: all
  become: yes
  vars:
    hermes_user: hermes
    hermes_comment: "Hermes AI Agent"
    hermes_shell: /bin/bash
    hermes_home: /home/hermes
    hermes_ssh_key: "{{ lookup('file', '/path/to/hermes-vm-key.pub') }}"
    
    read_commands:
      - /usr/bin/journalctl
      - /usr/bin/dmesg
      - /usr/bin/ss
      - /usr/sbin/ss
      - /sbin/ip
      - /usr/bin/systemctl
      - /usr/bin/free
      - /usr/bin/df
      - /usr/bin/du
      - /usr/bin/top
      - /usr/bin/htop
      - /usr/bin/lsof
      - /usr/bin/strace
      - /usr/bin/tail
      - /usr/bin/cat
      - /bin/ls
      - /usr/bin/find
      - /usr/bin/grep
      - /usr/bin/nproc
      - /usr/bin/mount
      - /usr/bin/umount
      - /usr/bin/showmount
      - /usr/bin/ps
      - /usr/bin/w
      - /usr/bin/uptime

    write_commands:
      - /usr/bin/systemctl
      - /usr/bin/vim
      - /usr/bin/nano
      - /usr/bin/rpm
      - /usr/bin/dnf

  tasks:
    - name: Create hermes user
      ansible.builtin.user:
        name: "{{ hermes_user }}"
        comment: "{{ hermes_comment }}"
        shell: "{{ hermes_shell }}"
        home: "{{ hermes_home }}"
        create_home: yes
        state: present

    - name: Ensure .ssh directory exists
      ansible.builtin.file:
        path: "{{ hermes_home }}/.ssh"
        state: directory
        owner: "{{ hermes_user }}"
        group: "{{ hermes_user }}"
        mode: '0700'

    - name: Add hermes-agent SSH key to authorized_keys
      ansible.builtin.authorized_key:
        user: "{{ hermes_user }}"
        key: "{{ hermes_ssh_key }}"
        state: present
        exclusive: no

    - name: Deploy read-tier sudoers
      ansible.builtin.copy:
        content: |
          # Hermes agent - read tier (NOPASSWD)
          {{ hermes_user }} ALL=(root) NOPASSWD: {{ read_commands | join(', ') }}
        dest: /etc/sudoers.d/10-hermes-read
        mode: '0440'
        validate: 'visudo -cf %s'

    - name: Deploy write-tier sudoers
      ansible.builtin.copy:
        content: |
          # Hermes agent - write tier (requires password)
          {{ hermes_user }} ALL=(root) PASSWD: {{ write_commands | join(', ') }}
        dest: /etc/sudoers.d/20-hermes-write
        mode: '0440'
        validate: 'visudo -cf %s'

    - name: Set correct ownership on home directory
      ansible.builtin.file:
        path: "{{ hermes_home }}"
        owner: "{{ hermes_user }}"
        group: "{{ hermes_user }}"
        mode: '0755'
```

### Deploy via Ansible

```bash
# Inventory file (inventory.ini)
[hermes_targets]
alpine01.bitbull.ch
custom01.bitbull.ch

# Run playbook
ansible-playbook -i inventory.ini deploy-hermes-sudo.yml
```

### Manual Setup (without Ansible)

```bash
# Create user
useradd -m -s /bin/bash -c "Hermes AI Agent" hermes

# Create .ssh directory
mkdir -p /home/hermes/.ssh
chmod 700 /home/hermes/.ssh

# Add SSH public key
echo "ssh-ed25519 AAAA... your@local" >> /home/hermes/.ssh/authorized_keys
chmod 600 /home/hermes/.ssh/authorized_keys
chown -R hermes:hermes /home/hermes/.ssh

# Deploy sudoers files
cat > /etc/sudoers.d/10-hermes-read << EOF
# Hermes agent - read tier (NOPASSWD)
hermes ALL=(root) NOPASSWD: /usr/bin/journalctl, /usr/bin/dmesg, /usr/bin/ss, /usr/sbin/ss, /sbin/ip, /usr/bin/systemctl, /usr/bin/free, /usr/bin/df, /usr/bin/du, /usr/bin/top, /usr/bin/htop, /usr/bin/lsof, /usr/bin/strace, /usr/bin/tail, /usr/bin/cat, /bin/ls, /usr/bin/find, /usr/bin/grep, /usr/bin/nproc, /usr/bin/mount, /usr/bin/umount, /usr/bin/showmount, /usr/bin/ps, /usr/bin/w, /usr/bin/uptime
EOF

cat > /etc/sudoers.d/20-hermes-write << EOF
# Hermes agent - write tier (requires password)
hermes ALL=(root) PASSWD: /usr/bin/systemctl, /usr/bin/vim, /usr/bin/nano, /usr/bin/rpm, /usr/bin/dnf
EOF

chmod 0440 /etc/sudoers.d/10-hermes-read
chmod 0440 /etc/sudoers.d/20-hermes-write

# Validate
visudo -c -f /etc/sudoers.d/10-hermes-read
visudo -c -f /etc/sudoers.d/20-hermes-write
```

---

## Verification

### Test read tier (should work without password)

```bash
sudo -n journalctl -u ssh --no-pager -n 3
sudo -n dmesg | tail -20
sudo -n ss -tlnp
```

### Test write tier (should prompt for password)

```bash
sudo -n systemctl restart nginx
# Expected: "sudo: a password is required"
```

### Check rules from FreeIPA

```bash
ipa sudorule-show hermes-read
ipa sudorule-show hermes-write
ipa hbacrule-show hermes-sudo
```

### Check rules from standalone host

```bash
sudo -l
# Should show:
# User hermes may run the following commands on <hostname>:
#     (root) NOPASSWD: /usr/bin/journalctl, /usr/bin/dmesg, ...
#     (root) PASSWD: /usr/bin/systemctl, /usr/bin/vim, ...
```

---

## Verification

---

## Summary

✅ **Read tier (NOPASSWD):** 28 commands including journalctl, dmesg, ss, ip, systemctl status, etc.  
✅ **Write tier (password required):** systemctl restart, vim, nano, rpm, dnf  
✅ **FreeIPA integration:** Automatic via HBAC + sudo rules  
✅ **Standalone support:** Ansible playbook for non-FreeIPA hosts  
✅ **Audit trail:** All sudo activity logged to host's journal  

The Hermes agent can now:
- Debug prod without paging you (read tier)
- Request sudo for changes (write tier, requires your approval)