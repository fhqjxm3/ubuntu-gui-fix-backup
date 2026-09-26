#!/usr/bin/env bash
set -Eeuo pipefail
BACKUP_ROOT="${BACKUP_ROOT:-/mnt/backup}"
STAMP="$(date +%Y%m%d_%H%M%S)"
FINAL="$BACKUP_ROOT/system_data_backup_$STAMP.tar.zst"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
[[ $EUID -eq 0 ]] || { echo "sudo로 실행하세요."; exit 1; }
mountpoint -q "$BACKUP_ROOT" || { echo "$BACKUP_ROOT 가 별도 마운트가 아닙니다."; exit 1; }
[[ -w "$BACKUP_ROOT" ]] || { echo "$BACKUP_ROOT 쓰기 불가"; exit 1; }
for c in tar zstd sha256sum findmnt; do command -v "$c" >/dev/null || { echo "필수 명령 없음: $c"; exit 1; }; done
SOURCES=(/home /etc /root /usr/local /opt /srv)
while read -r tgt dev fs; do
 [[ "$dev" == /dev/* ]] || continue
 case "$fs" in proc|sysfs|devtmpfs|devpts|tmpfs|squashfs|overlay|autofs|cgroup*|efivarfs) continue;; esac
 case "$tgt" in /|/boot|/boot/efi|"$BACKUP_ROOT"|"$BACKUP_ROOT"/*) continue;; esac
 SOURCES+=("$tgt")
done < <(findmnt -rn -o TARGET,SOURCE,FSTYPE)
mapfile -t SOURCES < <(printf '%s
' "${SOURCES[@]}" | awk '!seen[$0]++' | while read -r p; do [[ -e "$p" ]] && printf '%s
' "$p"; done)
echo "백업 대상:"; printf '  %s
' "${SOURCES[@]}"
echo "출력: $FINAL"
tar --absolute-names --numeric-owner --acls --xattrs --xattrs-include='*' --selinux --sparse  --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run --exclude=/tmp  --exclude="$BACKUP_ROOT" -cpf - "${SOURCES[@]}" 2>"$WORK/tar.stderr" | zstd -T0 -1 -o "$FINAL.partial"
if grep -Eqi 'permission denied|read error|input/output error|cannot open|cannot stat' "$WORK/tar.stderr"; then
 mv "$FINAL.partial" "$FINAL.UNVERIFIED"; cat "$WORK/tar.stderr"; exit 2
fi
mv "$FINAL.partial" "$FINAL"
sync
echo "압축 스트림 검사..."
zstd -t "$FINAL"
echo "SHA256 생성..."
sha256sum "$FINAL" | tee "$FINAL.sha256"
echo "완료: $FINAL"
[[ -s "$WORK/tar.stderr" ]] && { echo "tar 경고:"; cat "$WORK/tar.stderr"; }
