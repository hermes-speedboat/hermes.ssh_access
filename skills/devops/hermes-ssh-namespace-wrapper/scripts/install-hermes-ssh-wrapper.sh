#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  install-hermes-ssh-wrapper.sh --diagnose
  install-hermes-ssh-wrapper.sh --install [--force] [--install-dir DIR]
  install-hermes-ssh-wrapper.sh --remove

Installs a context-local ssh wrapper for FreeIPA-joined Hermes runtimes where
OpenSSH sees root-owned /etc/ssh config files as nobody:nobody because of
systemd user namespaces / PrivateUsers sandboxing.

This wrapper is normally only needed when FreeIPA's SSH client drop-in exists:
  /etc/ssh/ssh_config.d/04-ipa.conf

If that file is absent, --install exits without changing anything unless
--force is supplied.

Environment used by the installed wrapper:
  HERMES_SSH_WRAPPER_DISABLE=1   bypass wrapper and exec real ssh
  HERMES_SSH_REAL=/path/to/ssh   real ssh binary, default /usr/bin/ssh
  XDG_CACHE_HOME=/path           cache base, default ~/.cache
USAGE
}

mode=""
force=0
install_dir="$HOME/.local/bin"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --diagnose|--install|--remove)
      mode="$1"
      shift
      ;;
    --force)
      force=1
      shift
      ;;
    --install-dir)
      install_dir="${2:-}"
      if [[ -z "$install_dir" ]]; then
        echo "ERROR: --install-dir needs a value" >&2
        exit 2
      fi
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$mode" ]]; then
  usage >&2
  exit 2
fi

wrapper_path="$install_dir/ssh"
marker="HERmes SSH namespace wrapper"
ipa_ssh_config="/etc/ssh/ssh_config.d/04-ipa.conf"

run_diagnose() {
  echo "== Identity =="
  id || true
  hostname -f 2>/dev/null || hostname || true

  echo
  echo "== Namespace maps =="
  echo "uid_map:"; cat /proc/self/uid_map 2>/dev/null || true
  echo "gid_map:"; cat /proc/self/gid_map 2>/dev/null || true

  echo
  echo "== SSH config ownership as seen from this context =="
  for p in /etc /etc/ssh /etc/ssh/ssh_config /etc/ssh/ssh_config.d /etc/ssh/ssh_config.d/*.conf /etc/crypto-policies/back-ends/openssh.config; do
    [[ -e "$p" ]] || continue
    stat -c '%n %A %a %u:%g %U:%G' "$p" || true
  done

  echo
  echo "== FreeIPA SSH client drop-in =="
  if [[ -e "$ipa_ssh_config" ]]; then
    echo "present: $ipa_ssh_config"
    stat -c '%n %A %a %u:%g %U:%G' "$ipa_ssh_config" || true
  else
    echo "absent: $ipa_ssh_config"
    echo "This FreeIPA-specific Hermes SSH wrapper is normally not needed on this system."
  fi

  echo
  echo "== OpenSSH parse test without wrapper =="
  if command -v /usr/bin/ssh >/dev/null 2>&1; then
    /usr/bin/ssh -G github.com >/tmp/hermes-ssh-wrapper-diagnose.out 2>&1 && rc=0 || rc=$?
    sed -n '1,20p' /tmp/hermes-ssh-wrapper-diagnose.out
    rm -f /tmp/hermes-ssh-wrapper-diagnose.out
    echo "exit_code=$rc"
  else
    echo "ERROR: /usr/bin/ssh not found"
  fi

  echo
  echo "== PATH resolution =="
  type -a ssh || true
}

install_wrapper() {
  if [[ ! -e "$ipa_ssh_config" && "$force" -ne 1 ]]; then
    echo "ERROR: $ipa_ssh_config is not present." >&2
    echo "This skill is for FreeIPA-joined Hermes systems with the FreeIPA SSH client drop-in." >&2
    echo "No wrapper installed. Use --force only after confirming an equivalent FreeIPA SSH config path." >&2
    exit 1
  fi

  mkdir -p "$install_dir"

  if [[ -e "$wrapper_path" ]] && ! grep -q "$marker" "$wrapper_path" 2>/dev/null; then
    if [[ "$force" -ne 1 ]]; then
      echo "ERROR: $wrapper_path already exists and is not this wrapper." >&2
      echo "Use --force to replace it after reviewing the file." >&2
      exit 1
    fi
    cp -a "$wrapper_path" "$wrapper_path.backup.$(date +%Y%m%d%H%M%S)"
  fi

  cat > "$wrapper_path" <<'WRAPPER'
#!/usr/bin/env bash
# HERmes SSH namespace wrapper
set -euo pipefail

real_ssh="${HERMES_SSH_REAL:-/usr/bin/ssh}"

if [[ "${HERMES_SSH_WRAPPER_DISABLE:-}" == "1" ]]; then
  exec "$real_ssh" "$@"
fi

# Respect callers that deliberately selected a config file.
prev_was_F=0
for arg in "$@"; do
  if [[ "$prev_was_F" == "1" ]]; then
    exec "$real_ssh" "$@"
  fi
  case "$arg" in
    -F)
      prev_was_F=1
      ;;
    -F*)
      exec "$real_ssh" "$@"
      ;;
  esac
done

cache_base="${XDG_CACHE_HOME:-$HOME/.cache}/hermes-ssh-wrapper"
cache_root="$cache_base/root"
mkdir -p "$cache_root"
chmod 700 "$cache_base" "$cache_root"

python3 - "$cache_root" "$HOME" <<'PY'
import glob
import os
import re
import shutil
import sys
from pathlib import Path

cache_root = Path(sys.argv[1])
home = Path(sys.argv[2])
seen = set()
include_re = re.compile(r'^(\s*Include\s+)(.+?)(\s*(?:#.*)?)$')


def split_patterns(value: str):
    # OpenSSH supports quoting in config values. Distribution Include lines are
    # normally simple whitespace-separated paths/globs; keep this intentionally
    # conservative rather than trying to be a full ssh_config parser.
    return value.split()


def cache_path_for(src: Path) -> Path:
    if src.is_absolute():
        return cache_root / str(src).lstrip('/')
    return cache_root / 'relative' / str(src)


def rewrite_file(src: Path) -> Path:
    src = src.resolve()
    dest = cache_path_for(src)
    if src in seen:
        return dest
    seen.add(src)
    dest.parent.mkdir(parents=True, exist_ok=True)

    try:
        text = src.read_text(errors='surrogateescape')
    except Exception:
        shutil.copy2(src, dest)
        os.chmod(dest, 0o600)
        return dest

    output = []
    for original_line in text.splitlines(True):
        stripped_newline = original_line.rstrip('\n')
        newline = '\n' if original_line.endswith('\n') else ''
        match = include_re.match(stripped_newline)
        if not match:
            output.append(original_line)
            continue

        prefix, rest, suffix = match.groups()
        rewritten = []
        for pattern in split_patterns(rest):
            expanded_pattern = os.path.expandvars(os.path.expanduser(pattern))
            matches = sorted(glob.glob(expanded_pattern)) or [expanded_pattern]
            for item in matches:
                path = Path(item)
                if not path.is_absolute():
                    path = (src.parent / path).resolve()
                if path.exists() and path.is_file():
                    rewrite_file(path)
                rewritten.append(str(cache_path_for(path)))
        output.append(prefix + ' '.join(rewritten) + suffix + newline)

    dest.write_text(''.join(output), errors='surrogateescape')
    os.chmod(dest, 0o600)
    return dest


system_config = Path('/etc/ssh/ssh_config')
generated_config = cache_root / 'hermes_ssh_config'
lines = ['# Generated by hermes-ssh-wrapper; do not edit.\n']

user_config = home / '.ssh' / 'config'
if user_config.exists():
    lines.append(f'Include {user_config}\n')

if system_config.exists():
    cached_system_config = rewrite_file(system_config)
    lines.append(f'Include {cached_system_config}\n')

generated_config.write_text(''.join(lines))
os.chmod(generated_config, 0o600)
PY

exec "$real_ssh" -F "$cache_root/hermes_ssh_config" "$@"
WRAPPER

  chmod 750 "$wrapper_path"
  echo "Installed: $wrapper_path"
  echo "Ensure this directory is before /usr/bin in PATH: $install_dir"
  echo "Verify with: type -a ssh && ssh -G github.com | sed -n '1,40p'"
}

remove_wrapper() {
  if [[ -e "$wrapper_path" ]] && grep -q "$marker" "$wrapper_path" 2>/dev/null; then
    rm -f "$wrapper_path"
    echo "Removed: $wrapper_path"
  else
    echo "No installed Hermes SSH namespace wrapper found at: $wrapper_path"
  fi
}

case "$mode" in
  --diagnose) run_diagnose ;;
  --install) install_wrapper ;;
  --remove) remove_wrapper ;;
esac
