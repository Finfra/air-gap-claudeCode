#!/usr/bin/env bash
# export.sh (v2) — 온라인(빌드) 호스트에서 실행. air-gap 반입 대상 docker 이미지를
#   tar 로 떨궈 무결성 매니페스트(SHA256SUMS)를 만들고, 매체 크기를 넘으면 자동 분할한다.
#   6.lms_MultiLLM_run/bringin/export.sh 의 v2 각색본 — 산출물이 bringin/_img 가 아니라
#   이 폴더(7.lms_MultiLLM_run_v2) 직속 _img/ 로 나가고, lms 는 CUDA 정상화본
#   (lms:31b-cuda11fix — 31B 전용 슬림본)을 반입한다.
#
#   짝: load.sh (단독망 호스트에서 검증 + docker load)
#
#   이미지명은 step4 의 .env(없으면 .env.org)를 읽어 run.sh 가 찾는 값과 자동 일치시킨다.
#   → 반입한 tar 의 태그 = run.sh 가 `docker image inspect` 하는 태그. 어긋날 여지 제거.
#
#   사용:
#     ./export.sh                 # step4/.env 의 3개 이미지를 _img/ 로 save + SHA256SUMS
#     ./export.sh --list          # 무엇을 내보낼지(태그·크기)만 출력, save 안 함
#     MEDIA_BYTES=50000000000 ./export.sh   # BD-R DL 50GB 기준 분할
#     MEDIA_BYTES=0 ./export.sh   # 분할 안 함(외장 디스크 등 단일 대용량 매체)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

IMG_DIR="_img"
ENV_FILE="step4.cc_gw_lms2/.env"
# 매체 1장 용량(바이트). 이보다 큰 tar 는 .partNN 로 쪼갠다.
#   DVD±R SL 물리 용량 = 4,707,319,808B. ISO9660/UDF 오버헤드 + 이 폴더의 문서·스크립트가
#   같은 디스크에 함께 들어가야 하므로 4.6GB 로 여유를 둔다(조각 1개 = 디스크 1장).
: "${MEDIA_BYTES:=4600000000}"

# step4/.env 에서 이미지 태그 확보 (없으면 .env.org, 그것도 없으면 하드 기본값)
if [ -f "$ENV_FILE" ]; then set -a; . "$ENV_FILE"; set +a
elif [ -f "step4.cc_gw_lms2/.env.org" ]; then set -a; . "step4.cc_gw_lms2/.env.org"; set +a
fi
: "${LMS_IMAGE:=lms:31b-cuda11fix}"
: "${GATEWAY_IMAGE:=lms-gateway:latest}"
: "${CLAUDE_IMAGE:=claude:latest}"

# 이미지 태그 → tar 파일명 (슬래시/콜론을 안전 문자로)
tarname() { echo "$1" | tr '/:' '__'; }

IMAGES=("$LMS_IMAGE" "$GATEWAY_IMAGE" "$CLAUDE_IMAGE")

human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1}B"; }

echo "[*] 반입 대상 이미지 (step4/.env 기준):"
TOTAL=0
for img in "${IMAGES[@]}"; do
  if ! sz="$(docker image inspect "$img" --format '{{.Size}}' 2>/dev/null)"; then
    echo "    ✗ $img — 이미지 없음. 먼저 빌드 후 재실행 (fail-loud)."
    echo "        lms:  cuda11fix/build_cuda11fix.sh + cuda11fix/build_slim31b.sh  (→ lms:31b-cuda11fix)"
    echo "        gw:   5.lms_MultiLLM/Dockerfile.gateway"
    echo "        cc:   6.lms_MultiLLM_run/_dockerfile/finfra/claude"
    exit 1
  fi
  echo "    · $img  ≈ $(human "$sz")  → $IMG_DIR/$(tarname "$img").tar"
  TOTAL=$(( TOTAL + sz ))
done
echo "    합계 ≈ $(human "$TOTAL")  (tar 는 비압축이라 이보다 약간 큼)"

# 매체 적합성 경고 — 정직하게. lms:31b-cuda11fix 는 DVD 를 크게 넘는다(~22GB → 5장).
if [ "$MEDIA_BYTES" -gt 0 ]; then
  echo
  echo "[*] 매체 1장 = $(human "$MEDIA_BYTES"). 이보다 큰 tar 는 .partNN 으로 분할한다."
  DISCS=$(( (TOTAL + MEDIA_BYTES - 1) / MEDIA_BYTES ))
  echo "    총량 기준 최소 매체 수 ≈ ${DISCS}장."
  if [ "$DISCS" -gt 3 ]; then
    echo "    ⚠️ 매체가 많이 필요하다. BD-R DL(50GB) 1장 또는 외장 디스크가 현실적:"
    echo "        MEDIA_BYTES=50000000000 ./export.sh   (BD-R DL)"
    echo "        MEDIA_BYTES=0            ./export.sh   (분할 안 함, 외장 디스크)"
  fi
fi

if [ "${1:-}" = "--list" ]; then exit 0; fi

echo
echo "[*] docker save → $IMG_DIR/ (시간 걸림; lms 는 수 분)"
mkdir -p "$IMG_DIR"
rm -f "$IMG_DIR"/*.tar "$IMG_DIR"/*.part?? "$IMG_DIR/SHA256SUMS" "$IMG_DIR/MANIFEST.txt" 2>/dev/null || true

for img in "${IMAGES[@]}"; do
  base="$(tarname "$img")"
  tar="$IMG_DIR/${base}.tar"
  echo "    · save $img → $tar"
  docker save "$img" -o "$tar"
  # 이미지 태그 ↔ tar 대응을 매니페스트로 남긴다(load.sh 가 태그 검증에 사용)
  printf '%s\t%s\n' "${base}.tar" "${img}" >> "$IMG_DIR/MANIFEST.txt"

  # 매체 초과 시 분할
  tsz=$(stat -c '%s' "$tar")
  if [ "$MEDIA_BYTES" -gt 0 ] && [ "$tsz" -gt "$MEDIA_BYTES" ]; then
    echo "      → $(human "$tsz") > 매체 크기 — 분할 (${base}.tar.partNN)"
    split -b "$MEDIA_BYTES" -d -a 2 "$tar" "${tar}.part"
    rm -f "$tar"
  fi
done

echo
echo "[*] SHA256SUMS 생성 (매체 손상 검증용)"
( cd "$IMG_DIR" && sha256sum *.tar *.tar.part?? 2>/dev/null > SHA256SUMS ) || true
echo "    $(wc -l < "$IMG_DIR/SHA256SUMS") 개 항목 → $IMG_DIR/SHA256SUMS"

echo
echo "─────────────────────────────────────────────────────────────"
echo " 굽기: 이 폴더(7.lms_MultiLLM_run_v2) 전체를 매체에 담는다."
echo "       tar 가 매체보다 크면 _img/*.part?? 를 여러 매체에 나눠 담고,"
echo "       단독망에서 같은 _img/ 로 다시 모으면 load.sh 가 이어붙인다."
echo " 단독망: ./load.sh  (SHA256 검증 → docker load → 태그 확인)"
echo " 모델:   lms:31b-cuda11fix 에 내장(google/gemma-4-31b-qat) — 별도 모델 반입 불필요."
echo "─────────────────────────────────────────────────────────────"
