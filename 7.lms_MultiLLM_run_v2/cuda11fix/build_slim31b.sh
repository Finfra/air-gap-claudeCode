#!/usr/bin/env bash
# build_slim31b.sh — 31B 전용 슬림 lms 이미지 빌드 (CUDA 11 런타임 노출 반영본)
#
#   lms:small-cuda11fix (29.1GB, gemma-4-E2B + gemma-4-31B 동봉)
#     → lms:31b-cuda11fix (22.2GB, gemma-4-31B-QAT 만)
#
#   왜 flatten(export|import) 인가:
#     Dockerfile 의 `RUN rm -rf ...` 은 상위 레이어에 삭제 마커만 남긴다. 하위 레이어에
#     원본 4.2GB 가 그대로 남아 `docker save` 산출물 크기가 줄지 않는다 → DVD 장수 그대로.
#     컨테이너 파일시스템을 export 해 단일 레이어로 import 해야 실제로 빠진다.
#     대신 이미지 메타데이터(ENV/USER/WORKDIR/ENTRYPOINT)는 --change 로 재부여한다.
#
#   사용:
#     ./build_slim31b.sh                          # lms:small-cuda11fix → lms:31b-cuda11fix
#     ./build_slim31b.sh <base> <target>          # 태그 지정
set -euo pipefail

BASE="${1:-lms:small-cuda11fix}"
TARGET="${2:-lms:31b-cuda11fix}"
WORK_CTR="lms-slim31b-build"
# 제거 대상 — 31B 만 남긴다. (nomic 임베딩 84MB 는 유지)
DROP_DIR="/home/lms/.lmstudio/models/lmstudio-community/gemma-4-E2B-it-GGUF"
KEEP_MODEL="google/gemma-4-31b-qat"

docker image inspect "$BASE" >/dev/null 2>&1 || {
  echo "[!] 베이스 이미지 없음: $BASE"
  echo "    먼저: ./build_cuda11fix.sh   (lms:small → lms:small-cuda11fix)"
  exit 1
}

echo "[*] 1/3 베이스에서 E2B 모델 제거 (작업 컨테이너)"
docker rm -f "$WORK_CTR" >/dev/null 2>&1 || true
docker run --name "$WORK_CTR" -u 0 --entrypoint bash "$BASE" -c "
set -eu
rm -rf '$DROP_DIR'
# 이전 실행이 남긴 서버 설정 잔재 제거 (entrypoint 가 런타임에 새로 씀)
rm -f /home/lms/.lmstudio/.internal/http-server-config.json
echo '    models: ' \$(du -sh /home/lms/.lmstudio/models | cut -f1)
# fail-loud — cuda11fix 레이어(ldconfig 등록)가 살아 있는지 확인
ldconfig -p | grep -q 'libcudart\.so\.11' || { echo '[!] libcudart.so.11 미노출 — 베이스가 cuda11fix 본이 아님'; exit 1; }
echo '    cuda11fix: OK (libcudart.so.11 해석 가능)'
"

echo "[*] 2/3 flatten (docker export | docker import) — 수 분 소요"
docker export "$WORK_CTR" | docker import \
  --change 'USER lms' \
  --change 'WORKDIR /home/lms' \
  --change 'ENV PATH=/home/lms/.lmstudio/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
  --change 'ENV LC_ALL=C.UTF-8' \
  --change 'ENV DEBIAN_FRONTEND=noninteractive' \
  --change "ENV LMS_MODEL=${KEEP_MODEL}" \
  --change 'ENV LMS_CONTEXT_LENGTH=32768' \
  --change 'ENV LMS_PARALLEL=1' \
  --change 'ENTRYPOINT ["/usr/local/bin/entrypoint.lms.sh"]' \
  - "$TARGET"

docker rm -f "$WORK_CTR" >/dev/null

echo "[*] 3/3 산출물 검증"
docker run --rm --entrypoint bash "$TARGET" -lc '
set -e
ldconfig -p | grep libcudart.so.11
lms ls
' || { echo "[!] 검증 실패"; exit 1; }

echo
echo "    ✅ $TARGET  ≈ $(docker image inspect "$TARGET" --format '{{.Size}}' | numfmt --to=iec --suffix=B)"
echo "    다음: ../export.sh  (→ _img/ 로 DVD 분할 반입본 생성)"
