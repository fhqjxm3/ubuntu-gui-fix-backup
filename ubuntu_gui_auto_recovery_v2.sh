#!/usr/bin/env bash
# ubuntu_gui_auto_recovery_v2.sh
# Conservative automatic recovery for Ubuntu GUI freeze after login.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
[[ $EUID -eq 0 ]] || { echo "Run: sudo bash $0"; exit 1; }
U="${SUDO_USER:-}"
[[ -n "$U" && "$U" != root ]] || { echo "Run from a normal user's TTY with sudo."; exit 1; }
H="$(getent passwd "$U"|cut -d: -f6)"
G="$(id -gn "$U")"
TS="$(date +%Y%m%d_%H%M%S)"
BASE="/var/log/gui-auto-recovery-$TS"
mkdir -p "$BASE"
exec > >(tee -a "$BASE/run.log") 2>&1
echo "=== GUI AUTO RECOVERY v2 / $TS ==="

collect() {
  local tag="$1"; mkdir -p "$BASE/$tag"
  { cat /etc/os-release; uname -a; uptime; free -h; df -hT; df -ih; lsblk -f; findmnt; } >"$BASE/$tag/system.txt" 2>&1 || true
  lspci -nnk >"$BASE/$tag/lspci.txt" 2>&1 || true
  systemctl --failed --no-pager >"$BASE/$tag/failed-units.txt" 2>&1 || true
  systemctl status display-manager --no-pager -l >"$BASE/$tag/display-manager.txt" 2>&1 || true
  journalctl -b --no-pager -p warning..alert >"$BASE/$tag/journal-warning.txt" 2>&1 || true
  journalctl -b --no-pager | grep -Ei 'gdm|sddm|lightdm|gnome|kwin|plasma|Xorg|wayland|nvidia|nouveau|amdgpu|i915|drm|gpu|segfault|oom|out of memory|keyring' >"$BASE/$tag/gui-gpu.txt" 2>&1 || true
  dmesg -T 2>/dev/null | grep -Ei 'drm|gpu|i915|amdgpu|nvidia|nouveau|oom|error|fail|I/O' >"$BASE/$tag/dmesg.txt" || true
  dpkg --audit >"$BASE/$tag/dpkg-audit.txt" 2>&1 || true
}
collect before

# Safety gates
RA=$(df -Pk /|awk 'NR==2{print $4}')
HA=$(df -Pk "$H"|awk 'NR==2{print $4}')
if (( RA < 1048576 || HA < 1048576 )); then
 echo "[STOP] root/home has <1GiB free. Logs: $BASE"; exit 20
fi
if dmesg 2>/dev/null | grep -Eqi 'I/O error|EXT4-fs error|XFS.*Corruption|BTRFS.*error'; then
 echo "[STOP] Storage/filesystem errors detected. Avoid automated package writes. Logs: $BASE"; exit 21
fi

# Preserve relevant config before changes
mkdir -p "$BASE/backup"
cp -a /etc/gdm3 "$BASE/backup/" 2>/dev/null || true
cp -a /etc/X11 "$BASE/backup/" 2>/dev/null || true
for f in "$H/.Xauthority" "$H/.ICEauthority"; do cp -a "$f" "$BASE/backup/" 2>/dev/null || true; done

echo "=== package repair ==="
dpkg --configure -a || true
apt-get -f install -y || true

# Reinstall only already-installed display/session core.
P=()
for p in gdm3 sddm lightdm gnome-shell ubuntu-desktop ubuntu-desktop-minimal plasma-desktop plasma-workspace xserver-xorg-core xserver-xorg; do
 dpkg-query -W -f='${db:Status-Abbrev}' "$p" 2>/dev/null | grep -q '^ii' && P+=("$p") || true
done
if (("${#P[@]}")); then
 apt-get update || true
 apt-get install --reinstall -y "${P[@]}" || true
fi

echo "=== user-session isolation ==="
# Preserve, never delete. Cache reset is low-risk and reversible.
if [[ -d "$H/.cache" ]]; then mv "$H/.cache" "$H/.cache.pre_gui_fix_$TS"; fi
install -d -m700 -o "$U" -g "$G" "$H/.cache"
for f in "$H/.Xauthority" "$H/.ICEauthority"; do
 [[ -e "$f" ]] && mv "$f" "$f.pre_gui_fix_$TS"
done
chown "$U:$G" "$H"
for d in "$H/.cache" "$H/.config" "$H/.local"; do [[ -d "$d" ]] && chown "$U:$G" "$d"; done

# GDM + login freeze: prefer Xorg as a reversible compatibility fallback.
# Do not uninstall/change GPU drivers or kernels.
if dpkg-query -W -f='${db:Status-Abbrev}' gdm3 2>/dev/null | grep -q '^ii'; then
 CONF=/etc/gdm3/custom.conf
 if [[ -f "$CONF" ]]; then
   cp -a "$CONF" "$BASE/backup/custom.conf.before"
   if grep -qE '^[[:space:]]*#?[[:space:]]*WaylandEnable=' "$CONF"; then
     sed -Ei 's/^[[:space:]]*#?[[:space:]]*WaylandEnable=.*/WaylandEnable=false/' "$CONF"
   else
     if grep -q '^\[daemon\]' "$CONF"; then sed -i '/^\[daemon\]/a WaylandEnable=false' "$CONF"; else printf '\n[daemon]\nWaylandEnable=false\n' >>"$CONF"; fi
   fi
   echo "Applied reversible GDM Xorg fallback (WaylandEnable=false)."
 fi
fi

systemctl set-default graphical.target
systemctl daemon-reload
systemctl reset-failed || true
systemctl restart display-manager || true
sleep 5
collect after

cat >"$BASE/ROLLBACK.sh" <<EOF
#!/usr/bin/env bash
set -e
[[ \$EUID -eq 0 ]] || exit 1
if [[ -f "$BASE/backup/custom.conf.before" ]]; then cp -a "$BASE/backup/custom.conf.before" /etc/gdm3/custom.conf; fi
systemctl restart display-manager || true
echo "System-level GUI config rollback applied. User cache backups remain in $H."
EOF
chmod 700 "$BASE/ROLLBACK.sh"

echo
echo "=== DONE ==="
echo "Logs + rollback: $BASE"
echo "No GPU driver or kernel was removed/changed."
echo "Try GUI with Ctrl+Alt+F1/F2. If needed: sudo reboot"
