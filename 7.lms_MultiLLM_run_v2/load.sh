#!/usr/bin/env bash
# load.sh (v2) — 단독망(air-gap) 호스트에서 실행. export.sh 가 만든 _img/ 를 검증하고
#   docker load 한다. 6.lms_MultiLLM_run/bringin/load.sh 의 v2 각색본(_img/ 가 이 폴더 직속).
#   1) 분할본(.tar.partNN)이 있으면 이어붙여 원본 tar 복원
#   2) SHA256SUMS 로 매체 손상 검증 (실패 시 중단 — fail-loud)
#   3) docker load
#   4) MANIFEST 의 태그가 실제로 로드됐는지 확인 → run.sh 가 찾는 태그와 일치 보장
#
#   사용:
#     ./load.sh            # 검증 + 로드
#     ./load.sh --verify   # 검증만 (로드 안 함)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

IMG_DIR="_img"
[ -d "$IMG_DIR" ] || { echo "[!] $IMG_DIR 없음 — export.sh 산출물이 이 폴더에 있어야 함"; exit 1; }
cd "$IMG_DIR"

# 1) 무결성 검증 먼저 — SHA256SUMS 는 export 시점 형식(비분할=*.tar, 분할=*.tar.partNN).
#    분할 조각은 재조립 후에도 디스크에 남으므로, 여기서 조각/타르를 그대로 검사하면
#    매체 손상을 확실히 잡는다(재조립은 검증 통과 후에 한다).
if [ -f SHA256SUMS ]; then
  echo "[*] SHA256 검증 (매체 손상 확인)"
  sha256sum -c SHA256SUMS || { echo "[!] 체크섬 불일치 — 매체 손상. 재복사 필요."; exit 1; }
  echo "    ✅ 전 항목 일치"
else
  echo "[!] SHA256SUMS 없음 — 무결성 검증 생략(권장하지 않음)"
fi

if [ "${1:-}" = "--verify" ]; then echo "[+] 검증만 수행 — 재조립·로드 생략"; exit 0; fi

# 2) 분할본 재조립 — <base>.tar.part00, .part01 ... → <base>.tar (검증 통과 후)
for first in *.tar.part00; do
  [ -e "$first" ] || continue
  base="${first%.part00}"          # <name>.tar
  echo "[*] 분할본 재조립: ${base}.part* → ${base}"
  cat "${base}.part"?? > "$base"
done

# 3) docker load
echo "[*] docker load"
for t in *.tar; do
  echo "    · load $t"
  docker load -i "$t"
done

# 4) 태그 검증 — MANIFEST 에 적힌 이미지가 실제 로드됐는가
cd ..
if [ -f "$IMG_DIR/MANIFEST.txt" ]; then
  echo "[*] 로드된 태그 확인 (run.sh 가 찾는 값)"
  RC=0
  while IFS=$'\t' read -r _tar img; do
    [ -n "${img:-}" ] || continue
    if docker image inspect "$img" >/dev/null 2>&1; then
      echo "    ✅ $img"
    else
      echo "    ✗ $img — 로드 안 됨(태그 불일치 가능)"; RC=1
    fi
  done < "$IMG_DIR/MANIFEST.txt"
  [ "$RC" = 0 ] || { echo "[!] 일부 태그 누락 — run.sh 전에 해결"; exit 1; }
fi

echo
echo "─────────────────────────────────────────────────────────────"
echo " 다음: 서버 스택 기동"
echo "   cd step4.cc_gw_lms2 && cp .env.org .env && vi .env && ./run.sh"
echo "   판정: ./run.sh --check   (도달·shim·VRAM)"
echo " Windows 클라이언트 연결은 step5.win_gw_lms2/README.md"
echo " 모델: lms:31b-cuda11fix 내장(google/gemma-4-31b-qat) — 별도 반입 불필요"
echo "─────────────────────────────────────────────────────────────"
