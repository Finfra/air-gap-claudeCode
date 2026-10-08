#!/bin/sh
# 게이트웨이 upstream 목록 생성 — nginx 이미지의 /docker-entrypoint.d/ 에서 기동 시 실행
#   (복제본 수를 바꾼 뒤에는: docker compose exec gateway sh -c '/docker-entrypoint.d/40-vllm-upstreams.sh && nginx -s reload')
#
# 왜 필요한가 (fg1 실측 2026-10-08):
#   `server vllm:8000 resolve;` 한 줄이 복제본 N개 주소로 풀리면 consistent hash 가 세션 고정을 못 하고
#   라운드로빈으로 떨어진다 (같은 X-Session 6회가 3:3 으로 갈림 — nginx 1.27.5·1.30.3 동일).
#   복제본을 «이름별 server 한 줄씩» 나열하면 hash 가 정상 동작한다 (같은 세션 6회 → 한 백엔드).
#   그래서 서비스명 vllm 의 주소들을 역조회(Docker DNS PTR)해 복제본 컨테이너 이름을 얻고 한 줄씩 쓴다.
#   `resolve` 를 붙여 두므로 복제본이 재생성돼 IP 가 바뀌어도 따라간다.
set -eu

SERVICE="${VLLM_SERVICE:-vllm}"
PORT="${VLLM_PORT_INTERNAL:-8000}"
OUT="${VLLM_UPSTREAMS_FILE:-/etc/nginx/vllm-upstreams.conf}"
TRIES="${VLLM_RESOLVE_TRIES:-30}"

i=0
while :; do
  ips=$(getent ahostsv4 "$SERVICE" 2>/dev/null | awk '{print $1}' | sort -u)
  [ -n "$ips" ] && break
  i=$((i + 1))
  if [ "$i" -ge "$TRIES" ]; then
    echo "[vllm-upstreams] ERROR: '$SERVICE' 를 ${TRIES}회(2초 간격) 해석 못 함" >&2
    exit 1
  fi
  sleep 2
done

tmp="$OUT.tmp"
: > "$tmp"
for ip in $ips; do
  # PTR → "<컨테이너명>.<네트워크명>" — 첫 레이블만 쓴다. 역조회 실패면 IP 그대로 (resolve 없이)
  name=$(getent hosts "$ip" | awk '{print $2}' | cut -d. -f1)
  if [ -n "$name" ]; then
    echo "    server ${name}:${PORT} resolve;" >> "$tmp"
  else
    echo "    server ${ip}:${PORT};" >> "$tmp"
  fi
done
sort -o "$tmp" "$tmp"
mv "$tmp" "$OUT"
echo "[vllm-upstreams] $(grep -c server "$OUT") backend(s):"
sed 's/^ */[vllm-upstreams]   /' "$OUT"
