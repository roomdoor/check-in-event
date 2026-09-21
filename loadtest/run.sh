#!/usr/bin/env bash
# 측정 한 판. 초기화 -> 이벤트 생성 -> k6 -> 드레인 대기 -> 저장소에서 집계.
#
#   ./loadtest/run.sh
#   MODE=redis RATE=2000 DUP_RATIO=0.1 ./loadtest/run.sh
#
# k6 지표로는 판정하지 않는다. redis 모드는 응답이 persisted=false 로 즉시
# 돌아오므로, k6가 보는 처리율은 "접수 속도"지 "저장까지 끝낸 속도"가 아니다.
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
MODE="${MODE:-db}"
RATE="${RATE:-2000}"
DURATION="${DURATION:-1m}"
CAPACITY="${CAPACITY:-10000}"
DUP_RATIO="${DUP_RATIO:-0}"
PRE_VUS="${PRE_VUS:-50}"
MAX_VUS="${MAX_VUS:-200}"

REDIS_HOST="${REDIS_HOST:-localhost}"
REDIS_PORT="${REDIS_PORT:-6379}"
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-root}"
MYSQL_DATABASE="${MYSQL_DATABASE:-checkin_event}"

# 호스트에 클라이언트가 없으면 컴포즈 컨테이너 안의 것을 쓴다.
# 원격(EC2 등)을 볼 때는 통째로 덮어쓰면 된다.
#   REDIS_CLI="redis-cli -h 10.0.1.5"
if [ -z "${REDIS_CLI:-}" ]; then
  if command -v redis-cli >/dev/null; then
    REDIS_CLI="redis-cli -h ${REDIS_HOST} -p ${REDIS_PORT}"
  else
    REDIS_CLI="docker exec -i ${REDIS_CONTAINER:-checkin-redis} redis-cli"
  fi
fi
if [ -z "${MYSQL_CLI:-}" ]; then
  if command -v mysql >/dev/null; then
    MYSQL_CLI="mysql -h ${MYSQL_HOST} -P ${MYSQL_PORT} -u ${MYSQL_USER} -p${MYSQL_PASSWORD}"
  else
    MYSQL_CLI="docker exec -i ${MYSQL_CONTAINER:-checkin-mysql} mysql -u${MYSQL_USER} -p${MYSQL_PASSWORD}"
  fi
fi

DRAIN_CAP_SECONDS="${DRAIN_CAP_SECONDS:-600}"
DRAIN_POLL_SECONDS="${DRAIN_POLL_SECONDS:-2}"

# 드레이너 설정은 앱 기동 인자라 이 스크립트가 바꾸지 못한다. 결과에 조건을
# 남기려고 받아 적기만 한다 — 앱을 띄운 값과 반드시 같게 줄 것.
#   --checkin.redis.writer.batch-size=1000 --checkin.redis.writer.delay=100
WRITER_BATCH_SIZE="${WRITER_BATCH_SIZE:-200}"
WRITER_DELAY_MS="${WRITER_DELAY_MS:-500}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_ROOT="${RESULTS_ROOT:-${SCRIPT_DIR}/results}"

case "${MODE}" in
  db|redis) ;;
  *) echo "MODE 는 db 또는 redis 여야 한다. 받은 값: '${MODE}'" >&2; exit 1 ;;
esac
case "${RATE}" in
  ''|*[!0-9]*) echo "RATE 는 정수여야 한다. 받은 값: '${RATE}'" >&2; exit 1 ;;
esac
case "${CAPACITY}" in
  ''|*[!0-9]*) echo "CAPACITY 는 정수여야 한다. 받은 값: '${CAPACITY}'" >&2; exit 1 ;;
esac

command -v k6 >/dev/null || { echo "k6 가 없다." >&2; exit 1; }
command -v jq >/dev/null || { echo "jq 가 없다." >&2; exit 1; }

mysql_query() {
  ${MYSQL_CLI} -N -B -e "$1" "${MYSQL_DATABASE}" 2>/dev/null | tr -d '\r'
}

redis_cmd() {
  ${REDIS_CLI} "$@" 2>/dev/null | tr -d '\r'
}

echo "==> 사전 점검"
mysql_query "SELECT 1;" >/dev/null || { echo "MySQL 접속 실패 (${MYSQL_HOST}:${MYSQL_PORT})" >&2; exit 1; }
[ "$(redis_cmd PING)" = "PONG" ] || { echo "Redis 접속 실패 (${REDIS_HOST}:${REDIS_PORT})" >&2; exit 1; }

echo "==> 이벤트 생성 (capacity=${CAPACITY})"
create_body="$(printf '{"name":"loadtest-%s","capacity":%s}' "$(date +%s)" "${CAPACITY}")"
event_json="$(curl -fsS -X POST "${BASE_URL}/api/events" \
  -H 'Content-Type: application/json' -d "${create_body}")"
EVENT_ID="$(echo "${event_json}" | jq -r '.id')"
case "${EVENT_ID}" in
  ''|null|*[!0-9]*) echo "이벤트 생성 실패: ${event_json}" >&2; exit 1 ;;
esac
echo "    event_id=${EVENT_ID}"

# 이벤트를 새로 만들어도 스트림과 오프셋은 전역이라 지난 회차가 남는다.
echo "==> 상태 초기화"
redis_cmd DEL "event:${EVENT_ID}:users" "event:${EVENT_ID}:count" "event:${EVENT_ID}:pos" \
  checkins:stream checkins:stream:offset >/dev/null
mysql_query "DELETE FROM check_ins;" >/dev/null

run_id="${MODE}-rate${RATE}-dup${DUP_RATIO}-$(date +%Y%m%d-%H%M%S)"
run_dir="${RESULTS_ROOT}/${run_id}"
mkdir -p "${run_dir}"

echo "==> k6 (mode=${MODE} rate=${RATE} duration=${DURATION} dup=${DUP_RATIO})"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
k6_status=0
BASE_URL="${BASE_URL}" EVENT_ID="${EVENT_ID}" MODE="${MODE}" RATE="${RATE}" \
DURATION="${DURATION}" DUP_RATIO="${DUP_RATIO}" KEY_PREFIX="${run_id}" \
PRE_VUS="${PRE_VUS}" MAX_VUS="${MAX_VUS}" \
  k6 run --summary-export="${run_dir}/summary.json" "${SCRIPT_DIR}/checkin.js" \
  || k6_status=$?
[ "${k6_status}" -eq 0 ] || echo "k6 가 ${k6_status} 로 끝났다. 집계는 계속한다." >&2

# db 모드는 요청 안에서 저장까지 끝낸다. 드레인할 스트림이 없다.
drain_seconds=0
drain_capped=false
if [ "${MODE}" = "redis" ]; then
  echo "==> 드레인 대기 (추측하지 않는다. 오프셋이 스트림 끝에 닿을 때까지)"
  drain_started="${SECONDS}"
  while :; do
    last_id="$(redis_cmd XREVRANGE checkins:stream + - COUNT 1 | head -1)"
    offset="$(redis_cmd GET checkins:stream:offset)"
    if [ -z "${last_id}" ] || [ "${offset}" = "${last_id}" ]; then
      drain_seconds=$(( SECONDS - drain_started ))
      echo "    드레인 완료: ${drain_seconds}s"
      break
    fi
    if [ $(( SECONDS - drain_started )) -ge "${DRAIN_CAP_SECONDS}" ]; then
      drain_seconds=$(( SECONDS - drain_started ))
      drain_capped=true
      echo "    상한 ${DRAIN_CAP_SECONDS}s 초과. 남은 스트림이 있는 채로 집계한다." >&2
      break
    fi
    sleep "${DRAIN_POLL_SECONDS}"
  done
fi

echo "==> 집계 (저장소에서 센다)"
read -r db_accepted db_rejected db_total db_dup_keys evt_accepted evt_capacity <<EOF
$(mysql_query "SELECT
 (SELECT COUNT(*) FROM check_ins WHERE event_id=${EVENT_ID} AND accepted=1),
 (SELECT COUNT(*) FROM check_ins WHERE event_id=${EVENT_ID} AND accepted=0),
 (SELECT COUNT(*) FROM check_ins WHERE event_id=${EVENT_ID}),
 (SELECT COUNT(*) FROM (SELECT participant_key FROM check_ins WHERE event_id=${EVENT_ID}
    GROUP BY participant_key HAVING COUNT(*)>1) d),
 (SELECT accepted_count FROM events WHERE id=${EVENT_ID}),
 (SELECT capacity FROM events WHERE id=${EVENT_ID});")
EOF

redis_count="$(redis_cmd GET "event:${EVENT_ID}:count")"
redis_users="$(redis_cmd SCARD "event:${EVENT_ID}:users")"
redis_pos="$(redis_cmd HLEN "event:${EVENT_ID}:pos")"
stream_len="$(redis_cmd XLEN checkins:stream)"
: "${redis_count:=0}"

# k6 가 요약을 못 남기고 죽는 경우가 있다(스크립트 오류, 대상 불통, OOM).
# 그때 jq 를 그냥 부르면 set -e 로 여기서 스크립트가 끝나 버려서, 아래
# 불변식 검사가 정작 필요한 순간에 돌지 않는다.
k6_reqs=0
k6_dropped=0
k6_p95=0
if [ -f "${run_dir}/summary.json" ]; then
  k6_reqs="$(jq -r '.metrics.http_reqs.count // 0' "${run_dir}/summary.json")" || k6_reqs=0
  k6_dropped="$(jq -r '.metrics.dropped_iterations.count // 0' "${run_dir}/summary.json")" || k6_dropped=0
  k6_p95="$(jq -r '.metrics.http_req_duration["p(95)"] // 0' "${run_dir}/summary.json")" || k6_p95=0
else
  echo "k6 요약 파일이 없다. 부하 지표 없이 저장소 집계만 한다." >&2
fi
case "${k6_reqs}" in ''|*[!0-9]*) k6_reqs=0 ;; esac
case "${k6_dropped}" in ''|*[!0-9]*) k6_dropped=0 ;; esac

# 불변식. 하나라도 깨지면 이 회차는 성능 이전에 정확성이 틀린 것이다.
violations=""

# 아무 일도 안 일어난 회차부터 걸러야 한다. 나머지 검사는 전부 "같은가" 를
# 보기 때문에 0 끼리 비교하면 저절로 참이 된다. 앱이 체크인마다 500을 뱉어도
# 저장이 0건이라 모든 검사를 통과하고 "위반 없음" 이 나온다. 실제로 그랬다.
[ "${k6_reqs}" -gt 0 ] \
  || violations="${violations} 부하없음(k6 요청 0건)"
if [ "${k6_reqs}" -gt 0 ] && [ "${db_total:-0}" -eq 0 ]; then
  violations="${violations} 저장없음(요청 ${k6_reqs}건인데 저장 0건)"
fi

# 드레인이 상한에 걸렸다는 건 저장이 따라오지 못했다는 뜻이다. 이 상태에서는
# 아래 두 검사를 건너뛰므로, 건너뛴 사실 자체를 위반으로 남겨야 한다.
[ "${drain_capped}" = false ] \
  || violations="${violations} 드레인미완(${DRAIN_CAP_SECONDS}s 초과. Redis-DB 대조 생략됨)"

[ "${evt_accepted:-0}" -le "${evt_capacity:-0}" ] \
  || violations="${violations} 초과승인(accepted_count=${evt_accepted} > capacity=${evt_capacity})"
[ "${db_dup_keys:-0}" -eq 0 ] \
  || violations="${violations} 중복행(${db_dup_keys}개 키)"
# events.accepted_count 는 조회 API가 remaining 을 계산하는 근거다.
# 실제 승인 행 수와 어긋나면 API가 거짓말을 한다.
[ "${evt_accepted:-0}" -eq "${db_accepted:-0}" ] \
  || violations="${violations} 카운터불일치(accepted_count=${evt_accepted} vs 승인행=${db_accepted})"
if [ "${MODE}" = "redis" ] && [ "${drain_capped}" = false ]; then
  [ "${redis_count:-0}" -eq "${db_accepted:-0}" ] \
    || violations="${violations} Redis-DB불일치(redis=${redis_count} db=${db_accepted})"
  [ "${redis_users:-0}" -eq "${redis_pos:-0}" ] \
    || violations="${violations} 순번누락(users=${redis_users} pos=${redis_pos})"
fi
[ -n "${violations}" ] || violations="none"

jq -n \
  --arg run_id "${run_id}" --arg mode "${MODE}" --arg started_at "${started_at}" \
  --arg duration "${DURATION}" --arg dup_ratio "${DUP_RATIO}" \
  --arg violations "${violations}" \
  --argjson event_id "${EVENT_ID}" --argjson rate "${RATE}" \
  --argjson capacity "${evt_capacity:-0}" --argjson accepted_count "${evt_accepted:-0}" \
  --argjson db_accepted "${db_accepted:-0}" --argjson db_rejected "${db_rejected:-0}" \
  --argjson db_total "${db_total:-0}" --argjson db_dup_keys "${db_dup_keys:-0}" \
  --argjson redis_count "${redis_count:-0}" --argjson redis_users "${redis_users:-0}" \
  --argjson redis_pos "${redis_pos:-0}" --argjson stream_len "${stream_len:-0}" \
  --argjson drain_seconds "${drain_seconds}" --argjson drain_capped "${drain_capped}" \
  --argjson writer_batch "${WRITER_BATCH_SIZE}" --argjson writer_delay "${WRITER_DELAY_MS}" \
  --argjson k6_reqs "${k6_reqs}" --argjson k6_dropped "${k6_dropped}" --argjson k6_p95 "${k6_p95}" \
  '{run_id:$run_id, mode:$mode, started_at:$started_at, event_id:$event_id,
    load:{rate:$rate, duration:$duration, dup_ratio:$dup_ratio},
    writer:{batch_size:$writer_batch, delay_ms:$writer_delay},
    event:{capacity:$capacity, accepted_count:$accepted_count},
    db:{accepted:$db_accepted, rejected:$db_rejected, total:$db_total, duplicate_keys:$db_dup_keys},
    redis:{count:$redis_count, users:$redis_users, pos:$redis_pos, stream_len:$stream_len},
    drain:{seconds:$drain_seconds, capped:$drain_capped},
    k6:{requests:$k6_reqs, dropped_iterations:$k6_dropped, p95_ms:$k6_p95},
    violations:$violations}' > "${run_dir}/result.json"

echo
echo "==== ${run_id} ===="
echo "정원 ${evt_capacity} / 승인 ${evt_accepted}"
echo "DB   승인 ${db_accepted} · 거부 ${db_rejected} · 합계 ${db_total} · 중복키 ${db_dup_keys}"
[ "${MODE}" = "db" ] || echo "Redis count ${redis_count} · users ${redis_users} · pos ${redis_pos} · 스트림 누적 ${stream_len}(XTRIM 미적용)"
[ "${MODE}" = "db" ] || echo "드레인 ${drain_seconds}s (상한초과=${drain_capped})"
echo "k6   요청 ${k6_reqs} · 버려진 이터레이션 ${k6_dropped} · p95 ${k6_p95}ms"
echo "불변식 위반: ${violations}"
echo "결과: ${run_dir}/result.json"

[ "${violations}" = "none" ]
