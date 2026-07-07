---
name: hermes-ssh-namespace-wrapper
description: Fix OpenSSH client config ownership failures on FreeIPA-joined Hermes instances by installing a context-local ssh wrapper that mirrors system config into a safe user-owned cache.
version: 1.0.1
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [hermes, ssh, systemd, user-namespace, linux, troubleshooting]
    related_skills: [hermes-agent, linux-infrastructure-operations]
---

# Hermes SSH Namespace Wrapper

## Scope

This skill is only meant for **Hermes instances running on FreeIPA-joined Linux systems** where FreeIPA installed the SSH client drop-in:

```text
/etc/ssh/ssh_config.d/04-ipa.conf
```

If `/etc/ssh/ssh_config.d/04-ipa.conf` is not present, this specific FreeIPA/Hermes workaround is normally **not needed**. Diagnose the local SSH error separately instead of installing this wrapper by default.

## Problem

A Hermes instance running as a systemd **user** service on a FreeIPA-joined system can execute tools inside a restricted user namespace. This commonly happens when a service uses sandboxing options such as `ProtectHome=read-only`; in per-user service managers, systemd may implicitly enable `PrivateUsers=` for namespace support.

Inside that namespace, host-owned `root:root` files may appear as `nobody:nobody` because UID/GID 0 is not mapped into the service's user namespace. OpenSSH then rejects otherwise-correct global client config files:

```text
Bad owner or permissions on /etc/ssh/ssh_config.d/04-ipa.conf
Bad owner or permissions on /etc/ssh/ssh_config.d/50-redhat.conf
Bad owner or permissions on /etc/crypto-policies/back-ends/openssh.config
```

The host may show the files correctly:

```text
-rw-r--r--. 1 root root /etc/ssh/ssh_config.d/04-ipa.conf
```

But the Hermes tool context may show:

```text
-rw-r--r-- 1 nobody nobody /etc/ssh/ssh_config.d/04-ipa.conf
```

This is not an SSH target problem. It is the local execution context in which `ssh` runs.

## When to Use

Use this skill when all of the following are true:

- The system is FreeIPA-joined, indicated by `/etc/ssh/ssh_config.d/04-ipa.conf` being present.
- Hermes terminal commands fail before connecting with `Bad owner or permissions on /etc/ssh/...`.
- `stat -c '%u:%g %U:%G %n' /etc/ssh/ssh_config.d/*.conf` inside Hermes shows `65534:65534 nobody:nobody`, but the host/root shell shows `0:0 root:root`.
- `/proc/self/uid_map` inside Hermes maps only the Hermes user UID, for example:

  ```text
        1000       1000          1
  ```

- You need a reusable workaround on Hermes installations where you cannot or do not want to remove the service sandbox immediately.

Do **not** use this as the first fix when `/etc/ssh/ssh_config.d/04-ipa.conf` is absent or when the host files are actually misowned or group/world-writable. In those cases, diagnose the actual local SSH problem or fix host permissions first.

## Preferred Fix Order

1. **Host config is really wrong:** fix ownership and modes on the host.

   ```bash
   sudo chown root:root /etc/ssh /etc/ssh/ssh_config /etc/ssh/ssh_config.d /etc/ssh/ssh_config.d/*.conf
   sudo chmod 755 /etc/ssh /etc/ssh/ssh_config.d
   sudo chmod 644 /etc/ssh/ssh_config /etc/ssh/ssh_config.d/*.conf
   ```

2. **Hermes service sandbox causes namespace remapping:** if acceptable, adjust the Hermes systemd unit so OpenSSH sees root-owned system config as root-owned. Review settings such as `ProtectHome=`, `PrivateUsers=`, `RootDirectory=`, `RootImage=`, bind mounts, and user-namespace options.

3. **Use the wrapper when sandboxing should stay enabled:** install the context-local wrapper from this skill. It does not change the host and does not disable sandboxing. It makes OpenSSH read a generated config that preserves normal order:

   ```text
   command-line options
   ~/.ssh/config
   mirrored /etc/ssh/ssh_config and recursively mirrored Include files
   ```

## Install the Wrapper

After installing this skill into a Hermes profile, run:

```bash
~/.hermes/skills/devops/hermes-ssh-namespace-wrapper/scripts/install-hermes-ssh-wrapper.sh --diagnose
~/.hermes/skills/devops/hermes-ssh-namespace-wrapper/scripts/install-hermes-ssh-wrapper.sh --install
```

The installer refuses to install unless `/etc/ssh/ssh_config.d/04-ipa.conf` exists. Use `--force` only if you have manually confirmed that an equivalent FreeIPA SSH drop-in exists under a different path.

For a named profile:

```bash
profile=<profile>
~/.hermes/profiles/$profile/skills/devops/hermes-ssh-namespace-wrapper/scripts/install-hermes-ssh-wrapper.sh --diagnose
~/.hermes/profiles/$profile/skills/devops/hermes-ssh-namespace-wrapper/scripts/install-hermes-ssh-wrapper.sh --install
```

The installer writes:

```text
~/.local/bin/ssh
```

Make sure `~/.local/bin` appears before `/usr/bin` in the service/user `PATH`.

## Verify

Run inside the same Hermes context that previously failed:

```bash
type -a ssh
ssh -G github.com | sed -n '1,40p'
ssh -o BatchMode=yes -o ConnectTimeout=5 -T git@github.com
```

Expected outcome:

- `type -a ssh` shows `~/.local/bin/ssh` before `/usr/bin/ssh`.
- `ssh -G ...` no longer fails with `Bad owner or permissions`.
- SSH reaches the target or fails only for normal target/auth reasons.

To bypass the wrapper for comparison:

```bash
HERMES_SSH_WRAPPER_DISABLE=1 ssh -G github.com
```

To force a specific real SSH binary:

```bash
HERMES_SSH_REAL=/usr/bin/ssh ssh -G github.com
```

## How the Wrapper Works

The wrapper:

1. Preserves the current environment and process context.
2. Leaves explicit `ssh -F <config>` calls alone.
3. Copies `/etc/ssh/ssh_config` and recursively included files into:

   ```text
   ${XDG_CACHE_HOME:-~/.cache}/hermes-ssh-wrapper/root/
   ```

4. Rewrites absolute `Include` paths to point at the cached copies.
5. Creates a generated top-level config that includes `~/.ssh/config` first and the mirrored system config second.
6. Executes:

   ```bash
   /usr/bin/ssh -F <generated-config> "$@"
   ```

This is better than a wrapper that only does `ssh -F ~/.ssh/config`, because it keeps distribution defaults such as Red Hat crypto policy and FreeIPA/SSSD host-key lookups where they are readable from the Hermes context.

## Caveats

- The wrapper can only mirror files readable by the Hermes runtime. If a system include is unreadable, fix the service sandbox or file permissions.
- Exotic `Include` paths with complex shell quoting are not fully parsed; normal distribution paths and simple globs are supported.
- This wrapper solves local OpenSSH config parsing. It does not fix remote host-key mismatch, missing private keys, GSSAPI problems, or remote authentication policy.
- Long-term, prefer a Hermes service unit that exposes needed system config without confusing UID/GID ownership checks.

## References

- OpenSSH `ssh_config(5)`: config source order and user config permission requirements.
- `systemd.exec(5)`: `ProtectHome=` availability in user managers and its implicit `PrivateUsers=` behavior; `PrivateUsers=` UID/GID mapping to `nobody` when users are outside the namespace map.
