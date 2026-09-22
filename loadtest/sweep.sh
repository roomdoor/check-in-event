#!/usr/bin/env bash
# 여러 조합을 돌면서 회차마다 앱을 재기동한다. 부하 호스트(C)에서 돌린다.
#
#   . /etc/profile.d/bench.sh            # BASE_URL, SUT_INSTANCE_ID, AWS_REGION 등
#   export REDIS_HOST=<B 호스트 사설 IP>
#   export MYSQL_HOST=<B 호스트 사설 IP>
#   export MYSQL_PASSWORD="$(aws ssm get-parameter --region "$AWS_REGION" \
#     --name /<name_prefix>/db-password --with-decryption \
#     --query Parameter.Value --output text)"
#
#   ./loadtest/sweep.sh loadtest/config/drainer.env
#
# 위 셋을 안 주면 run.sh 가 로컬을 보게 되므로 회차마다 거부하고 멈춘다.
# 정확한 명령은 terraform output next_steps 에 있다.
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
# SSM executionTimeout 의 허용 범위다. 벗어나면 send-command 가 거부하는데,
# 그 실패가 회차마다 반복되어 스윕 전체가 빈손으로 끝난다.
if [ "${APP_START_TIMEOUT}" -lt 30 ] || [ "${APP_START_TIMEOUT}" -gt 172800 ]; then
  echo "APP_START_TIMEOUT 은 30~172800 이어야 한다(SSM 제한). 받은 값: '${APP_START_TIMEOUT}'" >&2
  exit 1
fi
# run.sh 는 DURATION 을 k6 에 그대로 넘기고 검증하지 않는다. '1min' 같은 값이면
# 회차마다 k6 가 실패하고, 부하 0 인 result.json 만 조합 수만큼 쌓인다.
case "${DURATION}" in
  *[0-9]s|*[0-9]m|*[0-9]h) ;;
  *) echo "DURATION 은 30s, 1m, 1h 형태여야 한다. 받은 값: '${DURATION}'" >&2; exit 1 ;;
esac
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

  # stderr 를 삼키지 않는다. 자격증명 만료, 멈춘 SSM 에이전트, 잘못된
  # 인스턴스 ID 가 전부 "앱을 못 띄웠다" 한 줄로만 보이면, 12회차를 다 돌고
  # 나서도 무엇이 문제였는지 알 수 없다.
  local err_file
  err_file="$(mktemp)"
  cmd_id="$(aws ssm send-command --region "${AWS_REGION}" \
    --instance-ids "${SUT_INSTANCE_ID}" \
    --document-name AWS-RunShellScript \
    --parameters "${params}" \
    --query 'Command.CommandId' --output text 2>"${err_file}")" || {
      echo "SSM send-command 실패:" >&2
      cat "${err_file}" >&2
      rm -f "${err_file}"
      return 1
    }
  rm -f "${err_file}"
  [ -n "${cmd_id}" ] && [ "${cmd_id}" != "None" ] || { echo "SSM 명령 ID 를 못 받았다" >&2; return 1; }

  local waited=0
  local status=Pending
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
# 표를 이 회차 것만 모으는 데 쓴다. find -newermt 는 로컬 시각을 받는다.
sweep_start_local="$(date '+%Y-%m-%d %H:%M:%S')"

for mode in ${MODES}; do
  # db 모드는 드레이너를 쓰지 않는다. 그 설정으로 스윕하면 같은 측정을
  # 조합 수만큼 반복하면서 EC2 시간만 쓴다.
  if [ "${mode}" = "db" ]; then
    # %% 로 자르면 앞에 공백이 있을 때 빈 문자열이 되어 회차가 0이 된다.
    # set -- 로 단어 분해하면 앞뒤 공백과 무관하다.
    set -- ${WRITER_BATCH_SIZES}; batch_list="$1"
    set -- ${WRITER_DELAYS};      delay_list="$1"
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
    # 설정 파일에서 읽은 나머지 값도 그대로 넘긴다. 안 넘기면 조용히 기본값이
    # 쓰이는데, 두 개는 결과를 왜곡한다 —
    #   DRAIN_CAP_SECONDS: 일부러 과부하를 준 회차가 기본 600s 안에 못 빠지면
    #     드레인미완 으로 실패 처리된다. 그건 재려던 것 자체다.
    #   MAX_VUS: 부족하면 k6 가 도착률을 못 맞추고 이터레이션을 버린다.
    #     그러면 "batch 를 키워도 안 늘었다" 가 아니라 부하가 안 간 것이다.
    # env 로 넘긴다. 명령어 앞 할당 자리에 ${VAR:+NAME=val} 를 쓰면 확장 결과가
    # 할당이 아니라 명령어로 해석되어 command not found 로 죽는다.
    round_env=(
      "RESULTS_ROOT=${SWEEP_ROOT}"
      "MODE=${mode}"
      "RATE=${rate}"
      "DURATION=${DURATION}"
      "CAPACITY=${CAPACITY}"
      "DUP_RATIO=${DUP_RATIO}"
      "WRITER_BATCH_SIZE=${batch}"
      "WRITER_DELAY_MS=${delay}"
    )
    [ -z "${DRAIN_CAP_SECONDS:-}" ]  || round_env+=("DRAIN_CAP_SECONDS=${DRAIN_CAP_SECONDS}")
    [ -z "${DRAIN_POLL_SECONDS:-}" ] || round_env+=("DRAIN_POLL_SECONDS=${DRAIN_POLL_SECONDS}")
    [ -z "${PRE_VUS:-}" ]            || round_env+=("PRE_VUS=${PRE_VUS}")
    [ -z "${MAX_VUS:-}" ]            || round_env+=("MAX_VUS=${MAX_VUS}")

    round_status=0
    env "${round_env[@]}" "${SCRIPT_DIR}/run.sh" || round_status=$?

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
# 이 회차 것만 센다. 같은 설정을 다시 돌리면 결과가 같은 디렉터리에 쌓이는데,
# 그걸 다 세면 위의 총계와 표가 어긋나고 어느 게 이번 것인지 알 수 없다.
find "${SWEEP_ROOT}" -name result.json -newermt "${sweep_start_local}" 2>/dev/null | sort | while read -r f; do
  # jq 가 깨진 파일에 실패하면 파이프라인이 0 이 아닌 상태를 내고, set -e 가
  # 여기서 스크립트를 끝낸다 — 아래 S3 업로드와 결과 경로 출력을 못 보고
  # 몇 시간짜리 스윕이 빈손으로 끝난다.
  jq -r '[.mode, (.writer.batch_size|tostring), (.writer.delay_ms|tostring),
          (.load.rate|tostring), (.event.capacity|tostring), (.db.accepted|tostring),
          ((.drain.seconds|tostring) + "s"), (.k6.p95_ms|tostring|.[0:7]), .violations]
         | @tsv' "$f" 2>/dev/null \
    | awk -F'\t' '{printf "%-6s %6s %6s %6s %8s %8s %8s %8s  %s\n",$1,$2,$3,$4,$5,$6,$7,$8,$9}' \
    || echo "  (읽을 수 없음: ${f})"
done || true

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
