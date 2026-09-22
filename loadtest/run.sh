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
#
# 폴백은 컨테이너 안에서 도는 클라이언트라 REDIS_HOST/MYSQL_HOST 를 못 쓴다.
# 원격 주소를 준 채로 폴백에 걸리면 k6 는 원격을 때리고 초기화·집계는 로컬을
# 건드려서, 로컬의 0 과 원격 트래픽을 비교한 뒤 자신 있게 틀린 답을 낸다.
# 그래서 조용히 넘어가지 않고 여기서 멈춘다.
is_local_host() {
  case "$1" in
    localhost|127.0.0.1|::1|'') return 0 ;;
    *) return 1 ;;
  esac
}
if [ -z "${REDIS_CLI:-}" ]; then
  if command -v redis-cli >/dev/null; then
    REDIS_CLI="redis-cli -h ${REDIS_HOST} -p ${REDIS_PORT}"
  elif is_local_host "${REDIS_HOST}"; then
    REDIS_CLI="docker exec -i ${REDIS_CONTAINER:-checkin-redis} redis-cli"
  else
    echo "REDIS_HOST=${REDIS_HOST} 를 줬는데 이 호스트에 redis-cli 가 없다." >&2
    echo "docker 폴백은 컨테이너 안을 보므로 그 주소로 못 간다." >&2
    echo "redis-cli 를 설치하거나 REDIS_CLI 를 직접 지정할 것." >&2
    exit 1
  fi
fi
if [ -z "${MYSQL_CLI:-}" ]; then
  if command -v mysql >/dev/null; then
    MYSQL_CLI="mysql -h ${MYSQL_HOST} -P ${MYSQL_PORT} -u ${MYSQL_USER} -p${MYSQL_PASSWORD}"
  elif is_local_host "${MYSQL_HOST}"; then
    MYSQL_CLI="docker exec -i ${MYSQL_CONTAINER:-checkin-mysql} mysql -u${MYSQL_USER} -p${MYSQL_PASSWORD}"
  else
    echo "MYSQL_HOST=${MYSQL_HOST} 를 줬는데 이 호스트에 mysql 클라이언트가 없다." >&2
    echo "docker 폴백은 컨테이너 안을 보므로 그 주소로 못 간다." >&2
    echo "mysql 클라이언트를 설치하거나 MYSQL_CLI 를 직접 지정할 것." >&2
    exit 1
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
# DUP_RATIO 는 0~1 의 소수다. 검증을 빼면 'abc' 가 NaN 이 되어 중복이 조용히
# 꺼진 채로 돌고, 회차는 성공으로 끝난다 — 엉뚱한 걸 재고 통과하는 셈이다.
case "${DUP_RATIO}" in
  0|1|0.[0-9]|0.[0-9][0-9]) ;;
  *) echo "DUP_RATIO 는 0 이상 1 이하여야 한다(예: 0, 0.1, 0.25, 1). 받은 값: '${DUP_RATIO}'" >&2; exit 1 ;;
esac
# 나머지 숫자 입력도 전부 막아둔다. 드레인 상한이 '10m' 이면 비교가 깨지는데
# if 조건 안이라 set -e 가 안 걸려서 상한이 영영 안 잡히고 루프가 안 끝난다.
# WRITER_* 는 jq 로 바로 들어가서, 'ms' 한 글자에 회차가 다 끝난 뒤 결과
# 파일을 쓰는 순간 죽는다.
for _name in DRAIN_CAP_SECONDS DRAIN_POLL_SECONDS WRITER_BATCH_SIZE WRITER_DELAY_MS PRE_VUS MAX_VUS; do
  eval "_val=\${${_name}}"
  case "${_val}" in
    ''|*[!0-9]*) echo "${_name} 은 정수여야 한다. 받은 값: '${_val}'" >&2; exit 1 ;;
  esac
done

# 워밍업 출처도 같은 이유로 막는다. 둘 다 --argjson 으로 들어가므로,
# 'yes' 나 '12k' 를 주면 부하와 드레인을 다 끝낸 뒤 마지막 jq 에서 죽고
# result.json 이 안 남는다. 스윕이 줄 때는 정규화되지만 손으로 돌릴 때가 있다.
WARMUP_REQUESTS="${WARMUP_REQUESTS:-0}"
case "${WARMUP_REQUESTS}" in
  ''|*[!0-9]*) echo "WARMUP_REQUESTS 는 정수여야 한다. 받은 값: '${WARMUP_REQUESTS}'" >&2; exit 1 ;;
esac
for _name in WARMUP_DRAIN_CAPPED WARMUP_ABOVE_THRESHOLD; do
  eval "_val=\${${_name}:-false}"
  case "${_val}" in
    true|false) eval "${_name}=\${_val}" ;;
    *) echo "${_name} 은 true 또는 false 여야 한다. 받은 값: '${_val}'" >&2; exit 1 ;;
  esac
done

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
redis_cmd DEL checkins:stream checkins:stream:offset >/dev/null

# 지난 회차들의 이벤트 키를 거둔다.
#
# event:<id>:* 를 EVENT_ID 로 지우는 건 의미가 없다 — 그 ID 는 방금 만든
# 것이라 아직 키가 없다. 실제로 쌓이는 건 이전 회차들 것이고, Redis 가
# maxmemory 없이 noeviction 으로 도는 데다 회차마다 워밍업까지 붙어서
# 승인 수만큼의 SET·HASH 가 계속 남는다. 측정 대상 호스트의 Redis 다.
#
# 방금 만든 이벤트의 키까지 지워지지만 아직 비어 있어 무해하다 — Lua 가
# 첫 승인 때 만든다.
_stale_keys="$(${REDIS_CLI} --scan --pattern 'event:*' 2>/dev/null | tr '\n' ' ')" || _stale_keys=""
[ -z "${_stale_keys}" ] || redis_cmd DEL ${_stale_keys} >/dev/null
# 행만 지우고 events.accepted_count 를 두면 지난 이벤트들이 "행은 없는데
# 참가자는 있다"는 상태로 남아 조회 API가 영구히 틀린 잔여 정원을 답한다.
# 둘을 같이 되돌린다.
#
# DELETE 가 아니라 TRUNCATE 다. DELETE 는 지운 행마다 undo 를 남기고 InnoDB 가
# 그걸 백그라운드로 정리하는데, 그 정리가 이번 회차의 드레인 측정과 겹친다.
# 스윕이 워밍업을 돌리면서 그 양이 커졌다 — ceiling.env 6400 회차면 19만 행이고,
# 드레이너는 배치마다 check_ins 를 count(*) 한다. 드레이너 처리량이 이 저장소의
# 측정 대상이라 그 위에 퍼지 부하를 얹으면 안 된다.
# check_ins 는 events 를 참조하는 쪽이고 이를 참조하는 테이블이 없어 TRUNCATE 가
# 허용된다(참조당하는 테이블이면 MySQL 이 거부한다).
#
# 바꾸면서 생기는 차이 둘을 막아둔다.
#   - TRUNCATE 는 메타데이터 락을 기다리는데 lock_wait_timeout 기본값이
#     1년이다. 워밍업 직후라 드레이너가 아직 INSERT 중일 수 있고, 그러면
#     몇 시간짜리 스윕이 여기서 조용히 선다. 60초로 끊는다.
#   - TRUNCATE 는 DROP 권한을 요구한다(DELETE 는 DELETE 권한이면 됐다).
#     MYSQL_USER 를 최소 권한 계정으로 바꾸면 여기서 막힌다.
# 여기만 stderr 를 살린다. mysql_query 는 stderr 를 버리므로 TRUNCATE 가
# 실패해도 조용한데, 행 수를 세서 추측하면 원인을 잘못 짚는다 — 락 대기
# 만료인지 권한 부족인지 MySQL 이 이미 말해준다. 그대로 올린다.
#
# 행 수로 판정하지 않는 이유가 하나 더 있다. 워밍업 직후라 드레이너가 아직
# 배치를 커밋할 수 있고, 그 행들은 워밍업의 event_id 를 달고 있어 이번 회차
# 집계에 안 들어온다(모든 집계가 event_id 로 거른다). 전역으로 세면 그걸
# 실패로 보고 멀쩡한 회차를 버린다.
_truncate_err="$(${MYSQL_CLI} -N -B \
  -e "SET SESSION lock_wait_timeout = 60; TRUNCATE TABLE check_ins;" \
  "${MYSQL_DATABASE}" 2>&1 >/dev/null)" || {
    echo "상태 초기화 실패 — check_ins TRUNCATE:" >&2
    echo "  ${_truncate_err}" >&2
    echo "  TRUNCATE 는 DROP 권한을 요구하고(DELETE 는 아니었다), 메타데이터 락을" >&2
    echo "  기다린다. MYSQL_USER=${MYSQL_USER} 권한과 드레이너 상태를 확인할 것." >&2
    exit 1
  }
mysql_query "UPDATE events SET accepted_count = 0;" >/dev/null

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

# 이벤트 행이 사라졌거나 쿼리가 실패하면 mysql 이 NULL 이나 빈 값을 뱉는다.
# 그대로 두면 [ NULL -le 0 ] 이 깨지고, 마지막 jq 의 --argjson 이 NULL 을
# 못 받아 결과 파일을 쓰기 직전에 회차 전체가 날아간다.
sql_read_failed=false
for _var in db_accepted db_rejected db_total db_dup_keys evt_accepted evt_capacity; do
  eval "_val=\${${_var}:-}"
  case "${_val}" in
    ''|*[!0-9]*) eval "${_var}=0"; sql_read_failed=true ;;
  esac
done

redis_count="$(redis_cmd GET "event:${EVENT_ID}:count")"
redis_users="$(redis_cmd SCARD "event:${EVENT_ID}:users")"
redis_pos="$(redis_cmd HLEN "event:${EVENT_ID}:pos")"
stream_len="$(redis_cmd XLEN checkins:stream)"
# GET 은 키가 없으면 빈 값을 준다. 나머지도 명령이 실패하면 비어 있을 수 있어
# 같은 이유(비교 깨짐, jq --argjson 실패)로 숫자로 맞춰둔다.
for _var in redis_count redis_users redis_pos stream_len; do
  eval "_val=\${${_var}:-}"
  case "${_val}" in
    ''|*[!0-9]*) eval "${_var}=0" ;;
  esac
done

# k6 가 요약을 못 남기고 죽는 경우가 있다(스크립트 오류, 대상 불통, OOM).
# 그때 jq 를 그냥 부르면 set -e 로 여기서 스크립트가 끝나 버려서, 아래
# 불변식 검사가 정작 필요한 순간에 돌지 않는다.
k6_reqs=0
k6_dropped=0
k6_p95=0
k6_dup_sent=0
k6_rejected=0
if [ -f "${run_dir}/summary.json" ]; then
  k6_reqs="$(jq -r '.metrics.http_reqs.count // 0' "${run_dir}/summary.json")" || k6_reqs=0
  k6_dropped="$(jq -r '.metrics.dropped_iterations.count // 0' "${run_dir}/summary.json")" || k6_dropped=0
  k6_p95="$(jq -r '.metrics.http_req_duration["p(95)"] // 0' "${run_dir}/summary.json")" || k6_p95=0
  k6_dup_sent="$(jq -r '.metrics.checkin_duplicate_sent.count // 0' "${run_dir}/summary.json")" || k6_dup_sent=0
  # 거절은 더 이상 DB 에 안 남는다(응답으로만 알린다). 그래서 거절 건수는
  # k6 쪽에서 가져와야 한다 — 안 그러면 결과 파일이 "거절 0건" 으로 보여
  # 부하가 안 걸린 것처럼 읽힌다.
  k6_rejected="$(jq -r '.metrics.checkin_rejected.count // 0' "${run_dir}/summary.json")" || k6_rejected=0
else
  echo "k6 요약 파일이 없다. 부하 지표 없이 저장소 집계만 한다." >&2
fi
case "${k6_reqs}" in ''|*[!0-9]*) k6_reqs=0 ;; esac
case "${k6_dropped}" in ''|*[!0-9]*) k6_dropped=0 ;; esac
case "${k6_dup_sent}" in ''|*[!0-9]*) k6_dup_sent=0 ;; esac
case "${k6_rejected}" in ''|*[!0-9]*) k6_rejected=0 ;; esac

# 불변식. 하나라도 깨지면 이 회차는 성능 이전에 정확성이 틀린 것이다.
violations=""

# 아무 일도 안 일어난 회차부터 걸러야 한다. 나머지 검사는 전부 "같은가" 를
# 보기 때문에 0 끼리 비교하면 저절로 참이 된다. 앱이 체크인마다 500을 뱉어도
# 저장이 0건이라 모든 검사를 통과하고 "위반 없음" 이 나온다. 실제로 그랬다.
[ "${sql_read_failed}" = false ] \
  || violations="${violations} 집계실패(DB 에서 숫자를 못 읽음)"
[ "${k6_reqs}" -gt 0 ] \
  || violations="${violations} 부하없음(k6 요청 0건)"
if [ "${k6_reqs}" -gt 0 ] && [ "${db_total:-0}" -eq 0 ]; then
  violations="${violations} 저장없음(요청 ${k6_reqs}건인데 저장 0건)"
fi

# 드레인이 상한에 걸렸다는 건 저장이 따라오지 못했다는 뜻이다. 이 상태에서는
# 아래 두 검사를 건너뛰므로, 건너뛴 사실 자체를 위반으로 남겨야 한다.
[ "${drain_capped}" = false ] \
  || violations="${violations} 드레인미완(${DRAIN_CAP_SECONDS}s 초과. Redis-DB 대조 생략됨)"

# 초과 승인은 이 스크립트가 존재하는 이유다. 그러니 고장난 카운터에 기대면
# 안 된다 — events.accepted_count 는 redis 모드에서 늘 0 이라(이슈 #1)
# 0 <= capacity 로 언제나 통과한다. 정원 1만에 4만을 받아들여도 뜨는 건
# 아래 '카운터불일치' 하나뿐이고, 그건 무시하라고 적어둔 항목이다.
# 실제로 저장된 행과 Redis 카운터로 따로 본다.
[ "${db_accepted:-0}" -le "${evt_capacity:-0}" ] \
  || violations="${violations} 초과승인(승인행=${db_accepted} > capacity=${evt_capacity})"
[ "${redis_count:-0}" -le "${evt_capacity:-0}" ] \
  || violations="${violations} 초과승인_redis(count=${redis_count} > capacity=${evt_capacity})"
[ "${evt_accepted:-0}" -le "${evt_capacity:-0}" ] \
  || violations="${violations} 초과승인_카운터(accepted_count=${evt_accepted} > capacity=${evt_capacity})"
# 스키마 점검에 가깝다. 두 경로 모두 중복 행을 물리적으로 못 만든다
# (db 모드는 유니크 제약, redis 모드는 insert ignore). 유니크 인덱스가
# 사라진 경우에만 걸린다 — 동시 중복 차단이 되는지를 보는 검사가 아니다.
[ "${db_dup_keys:-0}" -eq 0 ] \
  || violations="${violations} 중복행(${db_dup_keys}개 키)"
# events.accepted_count 는 조회 API가 remaining 을 계산하는 근거다.
# 실제 승인 행 수와 어긋나면 API가 거짓말을 한다.
#
# 주의: 이슈 #1 이 고쳐지기 전까지 redis 모드는 이 검사에서 항상 걸린다.
# 스크립트 문제가 아니라 드러난 앱 결함이다(rewriteBatchedStatements=true 라
# 배치 반환값이 -2 로 와서 카운터가 한 번도 안 오른다).
[ "${evt_accepted:-0}" -eq "${db_accepted:-0}" ] \
  || violations="${violations} 카운터불일치(accepted_count=${evt_accepted} vs 승인행=${db_accepted})"
if [ "${MODE}" = "redis" ]; then
  # 드레인 상태와 무관하게 성립해야 한다. 카운터와 집합이 어긋나면 Lua 가
  # INCR 과 SADD 중 하나만 한 것이다.
  [ "${redis_count:-0}" -eq "${redis_users:-0}" ] \
    || violations="${violations} Redis내부불일치(count=${redis_count} users=${redis_users})"
  [ "${redis_users:-0}" -eq "${redis_pos:-0}" ] \
    || violations="${violations} 순번누락(users=${redis_users} pos=${redis_pos})"
  # 이건 저장이 다 끝나야 성립한다.
  if [ "${drain_capped}" = false ]; then
    [ "${redis_count:-0}" -eq "${db_accepted:-0}" ] \
      || violations="${violations} Redis-DB불일치(redis=${redis_count} db=${db_accepted})"
  fi
fi

# 중복을 보내라고 했는데 한 건도 안 나갔으면 중복 경로를 안 잰 것이다.
# acceptedKeys 가 안 차면(정원이 작거나 이벤트가 닫혀 있으면) 그렇게 된다.
case "${DUP_RATIO}" in
  0) ;;
  *) [ "${k6_dup_sent}" -gt 0 ] \
       || violations="${violations} 중복미발생(DUP_RATIO=${DUP_RATIO} 인데 재사용 0건)" ;;
esac

[ -n "${violations}" ] || violations="none"

jq -n \
  --arg run_id "${run_id}" --arg mode "${MODE}" --arg started_at "${started_at}" \
  --arg duration "${DURATION}" --arg dup_ratio "${DUP_RATIO}" \
  --arg violations "${violations}" \
  --arg base_url "${BASE_URL}" --arg redis_host "${REDIS_HOST}" --arg mysql_host "${MYSQL_HOST}" \
  --arg warmed_by "${WARMED_BY:-unknown}" \
  --argjson warmup_requests "${WARMUP_REQUESTS}" \
  --argjson warmup_drain_capped "${WARMUP_DRAIN_CAPPED}" \
  --argjson warmup_above_threshold "${WARMUP_ABOVE_THRESHOLD}" \
  --argjson pre_vus "${PRE_VUS}" --argjson max_vus "${MAX_VUS}" \
  --argjson event_id "${EVENT_ID}" --argjson rate "${RATE}" \
  --argjson capacity "${evt_capacity:-0}" --argjson accepted_count "${evt_accepted:-0}" \
  --argjson db_accepted "${db_accepted:-0}" --argjson db_rejected "${db_rejected:-0}" \
  --argjson db_total "${db_total:-0}" --argjson db_dup_keys "${db_dup_keys:-0}" \
  --argjson redis_count "${redis_count:-0}" --argjson redis_users "${redis_users:-0}" \
  --argjson redis_pos "${redis_pos:-0}" --argjson stream_len "${stream_len:-0}" \
  --argjson drain_seconds "${drain_seconds}" --argjson drain_capped "${drain_capped}" \
  --argjson writer_batch "${WRITER_BATCH_SIZE}" --argjson writer_delay "${WRITER_DELAY_MS}" \
  --argjson k6_reqs "${k6_reqs}" --argjson k6_dropped "${k6_dropped}" --argjson k6_p95 "${k6_p95}" \
  --argjson k6_dup_sent "${k6_dup_sent}" --argjson k6_rejected "${k6_rejected}" \
  '{run_id:$run_id, mode:$mode, started_at:$started_at, event_id:$event_id,
    # 어디서 돌았는지. 세 주소가 전부 로컬이면 한 머신에서 잰 것이고, 그 수치는
    # 무엇이 병목인지 구분되지 않아 쓸 수 없다. 파일만 보고 알 수 있어야 한다.
    where:{base_url:$base_url, redis_host:$redis_host, mysql_host:$mysql_host},
    load:{rate:$rate, duration:$duration, dup_ratio:$dup_ratio,
          pre_vus:$pre_vus, max_vus:$max_vus,
          # 이 회차 전에 앱을 데웠는지. 응답이 밀리초 단위라 그 차이가
          # 측정값보다 크다(README 5 장). 파일만 보고 알 수 있어야 한다.
          #   "30s"     : 스윕이 그 길이만큼 한 번 데웠다
          #   "30sx3"   : 요청 수가 모자라 3회 반복했다. 낮은 rate 와 db 모드는
          #               한 번으로 기준을 못 채워서 이 형태가 흔하다
          #   "none"    : 스윕이 데우려 했으나 부하가 안 나갔다 = 콜드
          #   "off"     : 워밍업을 끄고 일부러 콜드를 쟀다
          #   "unknown" : run.sh 를 손으로 돌렸다. 데웠는지는 돌린 사람만 안다
          # unknown 을 none 과 합치면 안 된다 — 이 저장소의 유일한 웜 측정이
          # 손으로 돌린 것이라, 합치면 그게 콜드로 기록된다.
          warmed_by:$warmed_by,
          # 길이만으로는 충분히 데워졌는지 알 수 없다. 낮은 rate 에서 30초면
          # 요청이 몇 천 건뿐이라 C2 컴파일 문턱에 못 미친다. 그래서 실제로
          # 나간 요청 수와, 그게 설정한 기준을 넘었는지를 같이 남긴다.
          #
          # 이름이 'sufficient' 가 아닌 이유가 있다. 그 기준(기본 2만)은
          # 검증된 값이 아니다 — 이 저장소에서 확인된 웜 상태는 38만 요청
          # 뒤였고, 37만을 콜드로 받은 회차는 여전히 p95 1,474ms 였다.
          # 넘었다고 해서 충분하다는 뜻이 아니라 '명백히 모자라지는 않다' 다.
          #
          # 웜 회차만 고르려면 warmed_by 만 보면 안 된다 —
          #   .load.warmed_by as $w | ($w != "off" and $w != "none"
          #     and $w != "unknown" and .load.warmup_above_threshold)
          warmup_requests:$warmup_requests,
          warmup_above_threshold:$warmup_above_threshold,
          # 워밍업이 드레인 상한에 걸렸으면 본 회차가 시작될 때 드레이너가
          # 한가하지 않았다. 밀린 항목 자체는 상태 초기화가 스트림과 오프셋을
          # 지우므로 아래 drain.seconds 에 안 들어온다. 남는 영향은 드레이너
          # 경합과 그때까지 커진 check_ins 테이블이다.
          warmup_drain_capped:$warmup_drain_capped},
    writer:{batch_size:$writer_batch, delay_ms:$writer_delay},
    event:{capacity:$capacity, accepted_count:$accepted_count},
    db:{accepted:$db_accepted, rejected:$db_rejected, total:$db_total, duplicate_keys:$db_dup_keys},
    redis:{count:$redis_count, users:$redis_users, pos:$redis_pos, stream_len:$stream_len},
    drain:{seconds:$drain_seconds, capped:$drain_capped},
    k6:{requests:$k6_reqs, dropped_iterations:$k6_dropped, p95_ms:$k6_p95,
        duplicate_sent:$k6_dup_sent, rejected:$k6_rejected},
    violations:$violations}' > "${run_dir}/result.json"

echo
echo "==== ${run_id} ===="
echo "정원 ${evt_capacity} / 승인 ${evt_accepted}"
echo "DB   승인 ${db_accepted} · 합계 ${db_total} · 중복키 ${db_dup_keys}"
echo "     (거절은 저장하지 않는다. k6 가 센 거절 ${k6_rejected}건)"
[ "${MODE}" = "db" ] || echo "Redis count ${redis_count} · users ${redis_users} · pos ${redis_pos} · 스트림 누적 ${stream_len}(XTRIM 미적용)"
[ "${MODE}" = "db" ] || echo "드레인 ${drain_seconds}s (상한초과=${drain_capped})"
echo "k6   요청 ${k6_reqs} · 버려진 이터레이션 ${k6_dropped} · 재사용 ${k6_dup_sent} · p95 ${k6_p95}ms"
echo "불변식 위반: ${violations}"
echo "결과: ${run_dir}/result.json"

[ "${violations}" = "none" ]
