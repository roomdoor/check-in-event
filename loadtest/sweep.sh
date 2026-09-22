#!/usr/bin/env bash
# 여러 조합을 돌면서 회차마다 앱을 재기동한다. 부하 호스트(C)에서 돌린다.
#
#   ./loadtest/sweep.sh loadtest/config/drainer.env
#
# 한 판을 도는 건 run.sh 다. 이 스크립트가 하는 일은 둘뿐이다 —
# 조합을 돌고, 조합마다 앱을 그 설정으로 다시 띄운다.
#
# 손으로 하면 앱 기동 인자와 run.sh 에 준 WRITER_* 를 사람이 맞춰야 하는데,
# run.sh 는 그 값을 result.json 에 받아 적기만 하고 검증하지 않는다.
# 어긋나면 결과 파일이 조용히 거짓말을 한다. 같은 변수에서 둘 다 나오게 한다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

CONFIG="${1:-}"
[ -n "${CONFIG}" ] || { echo "사용법: $0 <config.env>" >&2; exit 1; }
[ -f "${CONFIG}" ] || { echo "설정 파일이 없다: ${CONFIG}" >&2; exit 1; }
# shellcheck disable=SC1090
. "${CONFIG}"
CONFIG_NAME="$(basename "${CONFIG}" .env)"

MODES="${MODES:-redis}"
RATES="${RATES:-400}"
WRITER_BATCH_SIZES="${WRITER_BATCH_SIZES:-200}"
WRITER_DELAYS="${WRITER_DELAYS:-500}"
REPEATS="${REPEATS:-1}"
DURATION="${DURATION:-1m}"
CAPACITY="${CAPACITY:-10000}"
DUP_RATIO="${DUP_RATIO:-0}"

# 앱을 재기동할 대상. 부트스트랩이 /etc/profile.d/bench.sh 에 심어둔다.
SUT_INSTANCE_ID="${SUT_INSTANCE_ID:?SUT_INSTANCE_ID 가 필요하다. /etc/profile.d/bench.sh 를 source 했는지 확인할 것}"
AWS_REGION="${AWS_REGION:?AWS_REGION 이 필요하다}"
APP_RUN="${APP_RUN:-/usr/local/bin/app-run.sh}"
APP_START_TIMEOUT="${APP_START_TIMEOUT:-600}"

RESULTS_ROOT="${RESULTS_ROOT:-${SCRIPT_DIR}/results}"
SWEEP_ROOT="${RESULTS_ROOT}/${CONFIG_NAME}"

# 몇 시간짜리 스윕이 끝난 뒤 jq 단계에서 죽는 걸 막는다. run.sh 도 같은 이유로
# 자기 입력을 먼저 검사하는데, 여기서 걸러야 첫 회차 전에 멈춘다.
for _name in REPEATS CAPACITY APP_START_TIMEOUT; do
  eval "_val=\${${_name}}"
  case "${_val}" in
    ''|*[!0-9]*) echo "${_name} 은 정수여야 한다. 받은 값: '${_val}'" >&2; exit 1 ;;
  esac
done
for _list_name in RATES WRITER_BATCH_SIZES WRITER_DELAYS; do
  eval "_list=\${${_list_name}}"
  for _v in ${_list}; do
    case "${_v}" in
      ''|*[!0-9]*) echo "${_list_name} 은 정수 목록이어야 한다. 받은 값: '${_v}'" >&2; exit 1 ;;
    esac
  done
done
for _m in ${MODES}; do
  case "${_m}" in
    db|redis) ;;
    *) echo "MODES 는 db 또는 redis 만. 받은 값: '${_m}'" >&2; exit 1 ;;
  esac
done

command -v aws >/dev/null || { echo "aws CLI 가 없다." >&2; exit 1; }
command -v jq >/dev/null || { echo "jq 가 없다." >&2; exit 1; }
[ -x "${SCRIPT_DIR}/run.sh" ] || { echo "run.sh 가 실행 가능해야 한다." >&2; exit 1; }

# 측정 대상 호스트에서 앱을 지정한 드레이너 설정으로 다시 띄운다.
# app-run.sh 가 뜰 때까지 기다리고 실패하면 컨테이너 로그를 stderr 로 뱉으므로,
# 여기서는 그 출력을 그대로 올려보내기만 한다.
app_restart() {
  local batch="$1" delay="$2"
  local params cmd_id status

  params="$(jq -n --arg b "${batch}" --arg d "${delay}" --arg run "${APP_RUN}" --arg t "${APP_START_TIMEOUT}" \
    '{commands: [($run + " --checkin.redis.writer.batch-size=" + $b + " --checkin.redis.writer.delay=" + $d)],
      executionTimeout: [$t]}')" || return 1

  cmd_id="$(aws ssm send-command --region "${AWS_REGION}" \
    --instance-ids "${SUT_INSTANCE_ID}" \
    --document-name AWS-RunShellScript \
    --parameters "${params}" \
    --query 'Command.CommandId' --output text 2>/dev/null)" || return 1
  [ -n "${cmd_id}" ] && [ "${cmd_id}" != "None" ] || return 1

  local waited=0
  while [ "${waited}" -lt "${APP_START_TIMEOUT}" ]; do
    status="$(aws ssm get-command-invocation --region "${AWS_REGION}" \
      --command-id "${cmd_id}" --instance-id "${SUT_INSTANCE_ID}" \
      --query 'Status' --output text 2>/dev/null)" || status=Pending
    case "${status}" in
      Success) return 0 ;;
      Failed|Cancelled|TimedOut)
        echo "앱 기동 실패 (${status}):" >&2
        # 순서 주의: >&2 를 먼저 둬야 stdout 이 진짜 stderr 로 간다.
        aws ssm get-command-invocation --region "${AWS_REGION}" \
          --command-id "${cmd_id}" --instance-id "${SUT_INSTANCE_ID}" \
          --query 'StandardErrorContent' --output text >&2 2>/dev/null || true
        return 1
        ;;
    esac
    sleep 5
    waited=$(( waited + 5 ))
  done
  echo "앱 기동이 ${APP_START_TIMEOUT}s 안에 끝나지 않았다 (마지막 상태: ${status})" >&2
  return 1
}

mkdir -p "${SWEEP_ROOT}"

total=0
failed=0
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

for mode in ${MODES}; do
  # db 모드는 드레이너를 쓰지 않는다. 그 설정으로 스윕하면 같은 측정을
  # 조합 수만큼 반복하면서 EC2 시간만 쓴다.
  if [ "${mode}" = "db" ]; then
    batch_list="${WRITER_BATCH_SIZES%% *}"
    delay_list="${WRITER_DELAYS%% *}"
  else
    batch_list="${WRITER_BATCH_SIZES}"
    delay_list="${WRITER_DELAYS}"
  fi

  for batch in ${batch_list}; do
  for delay in ${delay_list}; do
  for rate in ${RATES}; do
  for rep in $(seq 1 "${REPEATS}"); do
    total=$(( total + 1 ))
    label="${mode}/batch${batch}-delay${delay}/rate${rate}/rep${rep}"

    echo "=============================================================="
    echo "  ${CONFIG_NAME} / ${label}  (${total}번째)"
    echo "=============================================================="

    # 앱 기동과 run.sh 가 같은 변수를 쓴다. 이게 이 스크립트의 핵심이다.
    if ! app_restart "${batch}" "${delay}"; then
      echo "앱을 못 띄워서 이 회차는 건너뛴다: ${label}" >&2
      failed=$(( failed + 1 ))
      continue
    fi

    # 회차 하나가 실패해도 스윕은 계속한다. run.sh 는 불변식이 깨지면 1 로
    # 끝나는데, 그건 "이 조합에서 깨졌다" 는 결과이지 스윕의 실패가 아니다.
    round_status=0
    RESULTS_ROOT="${SWEEP_ROOT}" \
    MODE="${mode}" \
    RATE="${rate}" \
    DURATION="${DURATION}" \
    CAPACITY="${CAPACITY}" \
    DUP_RATIO="${DUP_RATIO}" \
    WRITER_BATCH_SIZE="${batch}" \
    WRITER_DELAY_MS="${delay}" \
      "${SCRIPT_DIR}/run.sh" || round_status=$?

    if [ "${round_status}" -ne 0 ]; then
      echo "회차가 불변식 위반으로 끝났다 (종료코드 ${round_status}): ${label}" >&2
      failed=$(( failed + 1 ))
    fi
  done
  done
  done
  done
done

# 결과를 표로 모은다. 회차마다 result.json 이 조건을 들고 있으므로 여기서
# 다시 계산할 것은 없다 — 읽어서 줄로 세우기만 한다.
echo
echo "=============================================================="
echo "  ${CONFIG_NAME} — ${total}회차 중 ${failed}회차 위반"
echo "=============================================================="
printf '%-6s %6s %6s %6s %8s %8s %8s %8s  %s\n' \
  mode batch delay rate 정원 승인 드레인 p95ms 위반
find "${SWEEP_ROOT}" -name result.json | sort | while read -r f; do
  jq -r '[.mode, (.writer.batch_size|tostring), (.writer.delay_ms|tostring),
          (.load.rate|tostring), (.event.capacity|tostring), (.db.accepted|tostring),
          ((.drain.seconds|tostring) + "s"), (.k6.p95_ms|tostring|.[0:7]), .violations]
         | @tsv' "$f" 2>/dev/null \
    | awk -F'\t' '{printf "%-6s %6s %6s %6s %8s %8s %8s %8s  %s\n",$1,$2,$3,$4,$5,$6,$7,$8,$9}'
done

if [ -n "${RESULTS_BUCKET:-}" ]; then
  echo
  echo "S3 로 올리는 중..."
  if aws s3 sync "${SWEEP_ROOT}/" "s3://${RESULTS_BUCKET}/results/${CONFIG_NAME}/" --only-show-errors; then
    echo "완료."
  else
    echo "S3 업로드 실패. 결과는 ${SWEEP_ROOT} 에 있다 — destroy 전에 회수할 것." >&2
  fi
fi

echo
echo "결과: ${SWEEP_ROOT}"
echo "시작: ${started_at}  종료: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# 전부 실패했으면 스윕 자체가 쓸모없다. 일부 실패는 결과다 — 천장을 찾으려면
# 깨지는 조합이 나와야 한다.
[ "${failed}" -lt "${total}" ] || { echo "모든 회차가 실패했다." >&2; exit 1; }
