#!/usr/bin/env bash
# home_linux_profile_recovery_v3.sh
# Reversible GNOME user-profile repair. User data is not deleted.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }
TARGET="${1:-home-linux}"
getent passwd "$TARGET" >/dev/null || { echo "User not found: $TARGET"; exit 2; }
HOME_DIR="$(getent passwd "$TARGET"|cut -d: -f6)"
GROUP="$(id -gn "$TARGET")"
TS="$(date +%Y%m%d_%H%M%S)"
SAVE="$HOME_DIR/.gui-profile-backup-$TS"
LOG="/var/log/home-profile-recovery-$TS.log"
exec > >(tee -a "$LOG") 2>&1
echo "Target=$TARGET Home=$HOME_DIR Backup=$SAVE"
mkdir -p "$SAVE"; chown "$TARGET:$GROUP" "$SAVE"; chmod 700 "$SAVE"

# Do not modify an actively logged-in target session.
if loginctl list-users --no-legend 2>/dev/null | awk '{print $2}' | grep -Fxq "$TARGET"; then
 echo "[STOP] $TARGET currently has an active login session. Log it out and run again from guitest/TTY."; exit 3
fi

# Inventory first.
{
 id "$TARGET"; find "$HOME_DIR" -maxdepth 1 -printf '%M %u:%g %p\n';
 sudo -u "$TARGET" dbus-run-session -- gsettings list-recursively org.gnome.desktop.interface 2>/dev/null || true
 sudo -u "$TARGET" dbus-run-session -- gnome-extensions list 2>/dev/null || true
} >"$SAVE/before.txt" 2>&1

# Preserve relevant settings; mv is reversible and avoids deleting content.
move_if_exists() {
 local p="$1" n
 [[ -e "$p" || -L "$p" ]] || return 0
 n="$(basename "$p")"
 mv "$p" "$SAVE/$n"
 echo "Preserved: $p -> $SAVE/$n"
}
move_if_exists "$HOME_DIR/.config/dconf"
move_if_exists "$HOME_DIR/.local/share/gnome-shell"
move_if_exists "$HOME_DIR/.config/gnome-session"
move_if_exists "$HOME_DIR/.config/monitors.xml"
move_if_exists "$HOME_DIR/.Xauthority"
move_if_exists "$HOME_DIR/.ICEauthority"

# Cache was already a suspect; preserve current cache again rather than delete.
if [[ -d "$HOME_DIR/.cache" ]]; then
 mv "$HOME_DIR/.cache" "$SAVE/cache"
fi
install -d -m700 -o "$TARGET" -g "$GROUP" "$HOME_DIR/.cache"
install -d -m700 -o "$TARGET" -g "$GROUP" "$HOME_DIR/.config"
install -d -m700 -o "$TARGET" -g "$GROUP" "$HOME_DIR/.local"
install -d -m700 -o "$TARGET" -g "$GROUP" "$HOME_DIR/.local/share"

# Repair only GNOME/session control-tree ownership. Never recursively chown Documents/Downloads/projects.
for p in "$HOME_DIR/.config" "$HOME_DIR/.cache" "$HOME_DIR/.local"; do
 chown "$TARGET:$GROUP" "$p"
done

# Remove stale per-user runtime only if target is logged out.
UIDN="$(id -u "$TARGET")"
if [[ -d "/run/user/$UIDN" ]] && ! loginctl user-status "$TARGET" >/dev/null 2>&1; then
 rm -rf "/run/user/$UIDN"
fi

# Ensure skeleton Desktop dirs are not required; preserve all personal files.
echo "Recovery prepared. No Documents/Downloads/Desktop/project data was deleted."
echo "Backup: $SAVE"
echo "Log: $LOG"
echo "Now reboot and login as $TARGET."
cat >"$SAVE/ROLLBACK.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
[[ \$EUID -eq 0 ]] || { echo "sudo required"; exit 1; }
T="$TARGET"; H="$HOME_DIR"; S="$SAVE"
restore(){ local src="\$1" dst="\$2"; [[ -e "\$src" ]] || return 0; [[ -e "\$dst" ]] && mv "\$dst" "\$dst.postfix-$TS"; mv "\$src" "\$dst"; }
restore "\$S/dconf" "\$H/.config/dconf"
restore "\$S/gnome-shell" "\$H/.local/share/gnome-shell"
restore "\$S/gnome-session" "\$H/.config/gnome-session"
restore "\$S/monitors.xml" "\$H/.config/monitors.xml"
restore "\$S/.Xauthority" "\$H/.Xauthority"
restore "\$S/.ICEauthority" "\$H/.ICEauthority"
restore "\$S/cache" "\$H/.cache"
chown -R "$TARGET:$GROUP" "\$S" || true
echo "Rollback completed. Reboot."
EOF
chmod 700 "$SAVE/ROLLBACK.sh"
chown -R "$TARGET:$GROUP" "$SAVE"
