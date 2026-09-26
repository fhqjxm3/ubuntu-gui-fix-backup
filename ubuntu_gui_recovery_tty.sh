#!/usr/bin/env bash
set -Eeuo pipefail
LOG="$HOME/gui_recovery_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
[[ $EUID -eq 0 ]] || { echo "sudo로 실행하세요."; exit 1; }
TARGET_USER="${SUDO_USER:-}"
[[ -n "$TARGET_USER" && "$TARGET_USER" != root ]] || { echo "일반 사용자에서 sudo로 실행하세요."; exit 1; }
HOME_DIR="$(getent passwd "$TARGET_USER"|cut -d: -f6)"
echo "=== 진단 ==="
cat /etc/os-release || true; uname -a; df -hT; df -ih; free -h
lspci -nnk | grep -EA4 'VGA|3D|Display' || true
systemctl --failed --no-pager || true
systemctl status display-manager --no-pager -l || true
journalctl -b -p warning..alert --no-pager -n 250 || true
journalctl -b --no-pager | grep -Ei 'gdm|sddm|lightdm|kwin|plasmashell|gnome-shell|Xorg|wayland|nvidia|nouveau|amdgpu|i915|drm|gpu|segfault|oom|out of memory' | tail -n 350 || true
root_avail=$(df -Pk /|awk 'NR==2{print $4}'); home_avail=$(df -Pk "$HOME_DIR"|awk 'NR==2{print $4}')
if ((root_avail<1048576 || home_avail<1048576)); then echo "루트/홈 여유공간 1GiB 미만. 자동수정 중단."; exit 20; fi
echo "=== 안전 복구 ==="
dpkg --configure -a
apt-get -f install -y
pkgs=()
for p in sddm gdm3 lightdm plasma-desktop plasma-workspace kde-standard ubuntu-desktop ubuntu-desktop-minimal gnome-shell xserver-xorg-core xserver-xorg; do
 dpkg-query -W -f='${db:Status-Abbrev}' "$p" 2>/dev/null|grep -q '^ii' && pkgs+=("$p") || true
done
if (("${#pkgs[@]}")); then apt-get update; apt-get install --reinstall -y "${pkgs[@]}"; fi
STAMP="$(date +%Y%m%d_%H%M%S)"
if [[ -d "$HOME_DIR/.cache" ]]; then
 mv "$HOME_DIR/.cache" "$HOME_DIR/.cache.pre_gui_recovery_$STAMP"
 install -d -m700 -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" "$HOME_DIR/.cache"
fi
for f in "$HOME_DIR/.Xauthority" "$HOME_DIR/.ICEauthority"; do [[ -e "$f" ]] && mv "$f" "$f.pre_gui_recovery_$STAMP"; done
chown "$TARGET_USER:$(id -gn "$TARGET_USER")" "$HOME_DIR"
for d in "$HOME_DIR/.cache" "$HOME_DIR/.config" "$HOME_DIR/.local"; do [[ -d "$d" ]] && chown "$TARGET_USER:$(id -gn "$TARGET_USER")" "$d"; done
systemctl set-default graphical.target
systemctl daemon-reload
systemctl restart display-manager || true
echo "=== 결과 ==="
systemctl status display-manager --no-pager -l || true
systemctl --failed --no-pager || true
echo "완료. GUI 전환: Ctrl+Alt+F1/F2, 재부팅: sudo reboot"
echo "로그: $LOG"
