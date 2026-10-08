#!/bin/bash
# finfra/claude 이미지 빌드 (step1~5 공용 Claude Code 클라이언트)
#
#   ./build.sh                          # 최신 claude-code 로 빌드 → finfra/claude:latest
#   ./build.sh --version 2.1.195        # 버전 고정(반입본 권장 — 재현 가능)
#   ./build.sh --tag claude:latest      # 기존 단계 스크립트 호환 태그 추가
#   ./build.sh --save                   # 빌드 후 _img/finfra-claude.tar 로 저장(폐쇄망 반입용)
#   ./build.sh --check                  # 빌드 없이 현재 이미지 게이트 판정
#
# ⚠️ 빌드는 인터넷이 필요하다(nodesource·npm). 폐쇄망에서는 --save 로 만든 tar 를
#    반입해 'docker load -i finfra-claude.tar' 로 올린다.
set -e
cd "$(dirname "$0")"

IMAGE="${IMAGE:-finfra/claude}"
TAG="${TAG:-latest}"
CLAUDE_VERSION="latest"
EXTRA_TAGS=()
DO_SAVE=0
DO_BUILD=1
SAVE_DIR="${SAVE_DIR:-./_img}"

while [ $# -gt 0 ]; do
  case "$1" in
    --version) CLAUDE_VERSION="$2"; shift 2 ;;
    --tag)     EXTRA_TAGS+=("$2"); shift 2 ;;
    --save)    DO_SAVE=1; shift ;;
    --check)   DO_BUILD=0; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "[!] 알 수 없는 인자: $1"; exit 1 ;;
  esac
done

REF="${IMAGE}:${TAG}"

if [ "$DO_BUILD" = "1" ]; then
  echo "[+] build ${REF}  (claude-code=${CLAUDE_VERSION}, uid/gid=$(id -u)/$(id -g))"
  BUILD_TAGS=(-t "$REF")
  for t in "${EXTRA_TAGS[@]}"; do BUILD_TAGS+=(-t "$t"); done

  # USER_UID/GID 를 호스트 사용자와 맞춘다 — 코드 디렉토리를 마운트했을 때
  #   컨테이너가 만든 파일이 root 소유로 남는 사고를 막는다.
  docker build \
    --build-arg USER_UID="$(id -u)" \
    --build-arg USER_GID="$(id -g)" \
    --build-arg CLAUDE_VERSION="$CLAUDE_VERSION" \
    "${BUILD_TAGS[@]}" .
  echo "[+] built: $REF ${EXTRA_TAGS[*]}"
fi

# ── 게이트 판정 ────────────────────────────────────────────────────────────
docker image inspect "$REF" >/dev/null 2>&1 || { echo "[!] 이미지 없음: $REF"; exit 1; }

echo
echo "── 게이트 판정 ──────────────────────────────────────────────"
FAIL=0

# 1) claude 실행 가능 + 버전 확인
VER="$(docker run --rm --entrypoint claude "$REF" --version 2>&1 | head -1)" \
  && echo "  ✅ 1 claude 실행 — $VER" \
  || { echo "  ❌ 1 claude 실행 실패"; FAIL=1; }

# 2) 백엔드 주소가 이미지에 구워져 있지 않을 것 (단계마다 다르므로 런타임 주입이어야 함)
if docker image inspect "$REF" --format '{{json .Config.Env}}' | grep -q 'ANTHROPIC_BASE_URL'; then
  echo "  ❌ 2 ANTHROPIC_BASE_URL 이 이미지에 구워짐 — 단계 간 재사용 불가"
  FAIL=1
else
  echo "  ✅ 2 백엔드 주소 미고정(런타임 주입)"
fi

# 3) PATH 선순위 — affinity shim 이 docker exec 에서도 잡히는지
PATH_HEAD="$(docker image inspect "$REF" --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep '^PATH=' | cut -d= -f2- | cut -d: -f1)"
[ "$PATH_HEAD" = "/home/ubuntu/.local/bin" ] \
  && echo "  ✅ 3 PATH 선순위 — $PATH_HEAD" \
  || { echo "  ❌ 3 PATH 선두가 ~/.local/bin 이 아님: $PATH_HEAD"; FAIL=1; }

# 4) settings 출력 모드 (step5 Windows 배포 경로) — 유효한 JSON 인지까지 확인
SETTINGS="$(docker run --rm -e CC_BASE_URL=http://192.168.0.4:8080 -e CC_MODEL=gemma-4-e2b-it \
  "$REF" settings 2>/dev/null)"
if echo "$SETTINGS" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);if(j.env.ANTHROPIC_BASE_URL!=="http://192.168.0.4:8080")process.exit(1);if(!j.permissions.deny.includes("WebSearch"))process.exit(1)})' 2>/dev/null; then
  echo "  ✅ 4 settings 출력 — 유효 JSON · base_url 반영 · WebSearch deny"
else
  echo "  ❌ 4 settings 출력 실패(JSON 파싱 또는 값 불일치)"
  FAIL=1
fi

# 5) 비루트 실행
WHO="$(docker run --rm --entrypoint id "$REF" -un 2>&1)"
[ "$WHO" = "ubuntu" ] && echo "  ✅ 5 기본 유저 — $WHO" \
  || { echo "  ❌ 5 기본 유저가 ubuntu 아님: $WHO"; FAIL=1; }

echo "─────────────────────────────────────────────────────────────"
[ "$FAIL" = "0" ] && echo "  전 게이트 통과" || { echo "  실패 있음"; exit 1; }

if [ "$DO_SAVE" = "1" ]; then
  mkdir -p "$SAVE_DIR"
  OUT="$SAVE_DIR/finfra-claude.tar"
  echo
  echo "[+] docker save → $OUT"
  docker save "$REF" "${EXTRA_TAGS[@]}" -o "$OUT"
  ( cd "$SAVE_DIR" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256" )
  ls -lh "$OUT"
  echo "[+] 반입 후: docker load -i $(basename "$OUT")"
fi
