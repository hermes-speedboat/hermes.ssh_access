# Hermes Instance Handoff

This document is the short operational handoff for another Hermes instance that needs to use the SSH access setup.

## Access Model

Use one SSH/Unix identity:

```text
hermes
```

The target-side sudo policy is intentionally broad:

```sudoers
hermes ALL=(ALL) NOPASSWD: ALL
```

This means the remote host will not block state-changing commands once Hermes submits them. The safety boundary is Hermes-side approval.

## Required Hermes Behavior

Use SSH as:

```bash
ssh hermes@HOSTNAME
```

Use sudo non-interactively:

```bash
sudo -n COMMAND
```

Never rely on, wait for, or attempt to answer an interactive remote sudo password prompt.

## Approval Rule

Read/debug commands may run directly.

Non-read or state-changing commands require explicit user approval before execution.

Rule of thumb:

```text
If the command writes files, changes services, changes packages, changes
users/groups, changes network/firewall state, changes mounts, changes kernel
runtime state, or intentionally modifies data: ask first.
```

## Read/Debug Examples

These normally do not require approval because they observe state only:

```bash
sudo -n journalctl --no-pager -n 100
sudo -n systemctl status sshd --no-pager
sudo -n systemctl show sshd
sudo -n ss -tlnp
sudo -n ip addr
sudo -n ip route
sudo -n ps aux
sudo -n free -m
sudo -n df -h
sudo -n du -sh /var/log
sudo -n cat /etc/some-config.conf
sudo -n tail -n 100 /var/log/messages
sudo -n grep PATTERN /path/to/file
sudo -n find /path -maxdepth 2 -type f
sudo -n getent passwd hermes
sudo -n id hermes
sudo -n ls -la /path
sudo -n stat /path
sudo -n -l
```

Be careful with tools that can be read-only or destructive depending on arguments. For example, `find` is read/debug only when it does **not** use actions such as `-delete` or `-exec` to modify state.

## Non-Read Examples Requiring Approval

Ask before running commands like these:

```bash
sudo -n systemctl restart SERVICE
sudo -n systemctl reload SERVICE
sudo -n systemctl start SERVICE
sudo -n systemctl stop SERVICE
sudo -n systemctl enable SERVICE
sudo -n systemctl disable SERVICE

sudo -n apt install PACKAGE
sudo -n apt remove PACKAGE
sudo -n apt-get upgrade
sudo -n dnf install PACKAGE
sudo -n dnf update
sudo -n yum remove PACKAGE
sudo -n apk add PACKAGE
sudo -n rpm -Uvh PACKAGE.rpm

echo content | sudo -n tee /etc/file.conf
sudo -n install -m 0644 SRC /etc/file.conf
sudo -n cp SRC DST
sudo -n mv SRC DST
sudo -n rm PATH
sudo -n chmod MODE PATH
sudo -n chown USER:GROUP PATH

sudo -n useradd USER
sudo -n usermod ...
sudo -n groupadd GROUP
sudo -n passwd USER

sudo -n firewall-cmd ...
sudo -n iptables ...
sudo -n nft ...
sudo -n ufw ...

sudo -n mount ...
sudo -n umount ...
sudo -n sysctl -w KEY=VALUE
```

Also ask before any shell pipeline whose purpose is to modify state.

## Verification Commands

Use these to confirm a target is ready:

```bash
ssh hermes@HOSTNAME 'whoami; id; hostname -f'
ssh hermes@HOSTNAME 'sudo -n whoami'
ssh hermes@HOSTNAME 'sudo -n -l'
```

Expected essentials:

```text
hermes
root
(root) NOPASSWD: ALL
```

On a FreeIPA-joined target, if sudo access was just changed, refresh SSSD and verify:

```bash
sudo sss_cache -E
sudo systemctl restart sssd
sudo -l -U hermes
```

## Hermes Runtime SSH Client Wrapper on FreeIPA Systems

This repository includes a Hermes skill for a local OpenSSH client problem that can affect Hermes instances running **on FreeIPA-joined systems**:

```text
skills/devops/hermes-ssh-namespace-wrapper/
```

Use it only if `/etc/ssh/ssh_config.d/04-ipa.conf` exists and OpenSSH fails inside Hermes with:

```text
Bad owner or permissions on /etc/ssh/ssh_config.d/04-ipa.conf
```

Typical diagnosis inside the Hermes context:

```bash
stat -c '%n %A %a %u:%g %U:%G' /etc/ssh/ssh_config.d/04-ipa.conf
cat /proc/self/uid_map
/usr/bin/ssh -G HOSTNAME
```

If `04-ipa.conf` appears as `nobody:nobody` inside Hermes but `root:root` on the host, install the skill into the active Hermes profile and run:

```bash
~/.hermes/skills/devops/hermes-ssh-namespace-wrapper/scripts/install-hermes-ssh-wrapper.sh --diagnose
~/.hermes/skills/devops/hermes-ssh-namespace-wrapper/scripts/install-hermes-ssh-wrapper.sh --install
```

If `/etc/ssh/ssh_config.d/04-ipa.conf` is absent, this FreeIPA-specific wrapper is normally not needed.

## FreeIPA Requirements

The `hermes` user must have HBAC access for both SSH and sudo.

HBAC rule essentials:

```text
HBAC Services: sshd
HBAC Service Groups: Sudo
```

Example FreeIPA rule:

```bash
ipa hbacrule-add "hermes-access"
ipa hbacrule-add-user "hermes-access" --users=hermes
ipa hbacrule-add-service "hermes-access" --hbacsvcs=sshd
ipa hbacrule-add-service "hermes-access" --hbacsvcgroups=Sudo
ipa hbacrule-mod "hermes-access" --hostcat=all
```

Sudo rule essentials:

```bash
ipa sudorule-add "hermes-all" \
  --desc="Full passwordless sudo for Hermes Agent; non-read commands require Hermes approval" \
  --hostcat=all \
  --runasusercat=all \
  --runasgroupcat=all \
  --cmdcat=all

ipa sudorule-add-user "hermes-all" --users=hermes
ipa sudorule-add-option "hermes-all" --sudooption='!authenticate'
```

Do not use `--hbacsvcs=Sudo` for sudo. The sudo side must use the service group form:

```bash
--hbacsvcgroups=Sudo
```

## Standing Instruction for Hermes

Use this text as standing context for an instance that will operate this access:

```text
For SSH sysadmin access, connect as hermes. The hermes user has full
passwordless sudo on configured Linux VMs. Use sudo -n for privileged
commands. Read/debug commands may run directly. Before any non-read or
state-changing command, ask the user for approval. Do not use YOLO mode
for production hosts. Do not rely on an interactive sudo password prompt.
After making a change, verify the result with real commands and report the
evidence.
```

## Important Limitations

- This is not a target-side security boundary. The target grants `hermes` full passwordless sudo.
- The approval boundary exists in Hermes. If Hermes approval is bypassed or misconfigured, the remote host will not stop state-changing commands.
- A compromised Hermes runtime or leaked `hermes` private key can perform root actions on allowed hosts.
- Separate Unix users can still be useful for logging, attribution, or key lifecycle management, but they are not a security gain if the same Hermes runtime can access all keys.
