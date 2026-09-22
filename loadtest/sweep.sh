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

# 본 측정 전에 흘려보낼 부하의 길이. 0 이면 끈다.
#
# 30s 는 6400 RPS 에서 약 19만 요청이다. 이 저장소에서 확인된 웜 상태는
# 38만 요청을 처리한 뒤였고, 37만을 콜드로 받은 회차는 여전히 p95 1,474ms 였다.
# 그 사이 어디서 충분해지는지는 안 재봤다 — 30s 는 근거 있는 출발점이지
# 검증된 문턱이 아니다.
WARMUP_DURATION="${WARMUP_DURATION:-30s}"

# 이 수를 못 넘기면 "데웠다" 로 안 적는다. 낮은 rate 에서 30초면 몇 천 건뿐인데,
# 그건 HotSpot 이 C2 까지 올리는 호출 수에 못 미친다. 정확한 문턱은 메서드마다
# 다르고 동적이라, 이 값은 "명백히 모자란 구간을 거른다" 는 용도다.
WARMUP_MIN_REQUESTS="${WARMUP_MIN_REQUESTS:-20000}"

# 기준을 못 채우면 몇 번까지 더 도는가. 길이가 아니라 나간 양으로 판단해야
# 낮은 rate 와 db 모드가 데워진다 — db 는 rate 를 올려도 앱이 초당 205건에서
# 포화하므로 30초에 6,000건이 천장이고, 한 번으로는 영원히 기준을 못 넘는다.
# 상한을 두는 이유는 앱이 아예 못 받는 상태일 때 무한히 도는 걸 막으려는 것이다.
WARMUP_MAX_ROUNDS="${WARMUP_MAX_ROUNDS:-4}"

# 워밍업 회차의 드레인 대기 상한. 본 회차 값을 물려받으면 안 된다 — 과부하
# 회차용으로 크게 잡아둔 값(예: 1800)을 워밍업이 쓰면, 출력이 버려진 채로
# 회차당 30분을 설 수 있다. 워밍업은 밀려도 버릴 회차라 짧게 끊는다.
WARMUP_DRAIN_CAP_SECONDS="${WARMUP_DRAIN_CAP_SECONDS:-120}"

# 워밍업이 끝나고 본 회차를 시작하기까지 쉬는 시간.
#
# redis 는 run.sh 가 드레인까지 기다려준 뒤라 짧아도 된다.
WARMUP_SETTLE_SECONDS="${WARMUP_SETTLE_SECONDS:-5}"

# db 는 드레인 단계가 없어서 워밍업의 마지막 트랜잭션이 아직 events 행 락을
# 쥐고 있을 수 있다. 그 위에서 본 회차의 상태 초기화와 첫 부하가 돈다.
WARMUP_DB_SETTLE_SECONDS="${WARMUP_DB_SETTLE_SECONDS:-30}"

# 앱을 재기동할 대상. 부트스트랩이 /etc/profile.d/bench.sh 에 심어둔다.
SUT_INSTANCE_ID="${SUT_INSTANCE_ID:?SUT_INSTANCE_ID 가 필요하다. /etc/profile.d/bench.sh 를 source 했는지 확인할 것}"
AWS_REGION="${AWS_REGION:?AWS_REGION 이 필요하다}"
APP_RUN="${APP_RUN:-/usr/local/bin/app-run.sh}"
APP_START_TIMEOUT="${APP_START_TIMEOUT:-600}"

RESULTS_ROOT="${RESULTS_ROOT:-${SCRIPT_DIR}/results}"
SWEEP_ROOT="${RESULTS_ROOT}/${CONFIG_NAME}"

# 워밍업 회차가 결과를 쓰는 자리. SWEEP_ROOT 밖에 둔다 — 안에 두면 끝에
# 표를 만들 때 같이 세어지고, S3 로도 올라간다.
# 실제 생성은 검증을 통과한 뒤에 한다(아래).
# config 이름을 붙여 스윕끼리 자리를 안 겹치게 한다.
#
# 그렇다고 두 스윕을 동시에 돌릴 수 있다는 뜻은 아니다 — run.sh 의 상태
# 초기화가 DB·Redis 를 전역으로 비우므로(스트림 DEL, check_ins TRUNCATE,
# accepted_count 0) 어차피 서로를 망가뜨린다. 여기 이름을 나누는 건
# 지난 실행의 잔재를 이번 실행이 읽지 않게 하려는 것이다.
warmup_root="${RESULTS_ROOT}/.warmup-${CONFIG_NAME}"
warmup_log="${warmup_root}/sweep-warmup.log"

# 몇 시간짜리 스윕이 끝난 뒤 jq 단계에서 죽는 걸 막는다. run.sh 도 같은 이유로
# 자기 입력을 먼저 검사하는데, 여기서 걸러야 첫 회차 전에 멈춘다.
for _name in REPEATS CAPACITY APP_START_TIMEOUT WARMUP_DRAIN_CAP_SECONDS \
             WARMUP_SETTLE_SECONDS WARMUP_DB_SETTLE_SECONDS WARMUP_MIN_REQUESTS \
             WARMUP_MAX_ROUNDS; do
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
# 워밍업도 같은 형태여야 한다. 잘못된 값이면 데우지 않은 채 모든 회차를
# 콜드로 재게 되는데, 그게 이 코드가 막으려는 상태다.
#
# 끄는 값을 여기서 한 번에 정규화한다. '0s' 같은 값이 형식 검사는 통과하면서
# "0 이 아니다" 로 분기하면, 끈 줄 알고 있는데 k6 가 0초 부하를 거부하고
# 그 실패가 회차마다 반복된다.
_warmup_bad() {
  echo "WARMUP_DURATION 은 0 또는 30s, 1m, 1m30s 형태여야 한다. 받은 값: '${WARMUP_DURATION}'" >&2
  exit 1
}
case "${WARMUP_DURATION}" in
  0) warmup_on=false ;;
  # DURATION 과 같은 형태만 받는다. '30' 처럼 단위가 없으면 k6 가
  # "missing unit" 으로 거부하고, 그 실패가 회차마다 반복된다.
  *[0-9]s|*[0-9]m|*[0-9]h)
    # 단위를 전부 떼고 숫자만 남긴다. '1m30s' 같은 복합 표기도 통과해야 한다.
    _warmup_num="${WARMUP_DURATION//[smh]/}"
    case "${_warmup_num}" in
      ''|*[!0-9]*) _warmup_bad ;;
      # 자리 중 하나라도 0 이 아니면 켠다. '0s'·'0m0s' 는 끈 것으로 본다 —
      # 형식은 맞지만 k6 는 0 길이 부하를 거부한다.
      *[1-9]*) warmup_on=true ;;
      *) warmup_on=false ;;
    esac ;;
  *) _warmup_bad ;;
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
# 검증을 통과한 뒤에 만든다. 위에 두면 설정이 틀려 멈춘 실행도 .warmup/ 을
# 남긴다.
# 워밍업 자리는 회차마다 쓰기 직전에 만든다(아래). 여기서는 만들지 않는다 —
# 스윕이 워밍업 없이 끝나면 빈 디렉터리조차 남기지 않는다.
#
# 어떻게 끝나든 지운다. Ctrl-C, SSH 끊김, set -e 중단 어느 쪽이든 남으면
# RESULTS_ROOT 아래에 있어 결과를 회수할 때 같이 딸려간다. 기본 경로
# (loadtest/results/)에서는 .gitignore 가 직계 자식을 막아주지만,
# RESULTS_ROOT 를 ec2/ 안으로 두고 돌리면 그 보호가 없다.
trap 'rm -rf "${warmup_root:?}"' EXIT

# 시작할 때도 비운다. trap 을 건너뛰는 종료(kill -9, 인스턴스 정지)가 있으면
# 남고, 워밍업을 끈 설정으로 다음 스윕을 돌리면 아무도 안 치운다.
rm -rf "${warmup_root:?}"

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

    # 재기동한 앱은 데우고 잰다.
    #
    # JVM 은 코드를 해석하다가 자주 도는 부분만 기계어로 컴파일하고, 클래스도
    # 처음 쓸 때 로딩한다. 이 서비스는 응답이 밀리초 단위라 그 비용이 측정값보다
    # 크다 — 같은 6400 RPS 가 따뜻하면 p95 2.15ms, 재기동 직후면 1474ms 였다.
    # 회차마다 재기동하므로, 데우지 않으면 매 회차가 그 1474ms 쪽을 잰다.
    #
    # run.sh 를 짧게 한 번 더 돌린다. 상태 초기화와 이벤트 생성이 그 안에 있다.
    # 결과는 버린다 — 불변식이 깨져도 워밍업 회차의 일이라 무시한다.
    #
    # 워밍업이 남긴 행이 본 회차 집계에 섞이지는 않는다(모든 집계가 event_id
    # 로 거른다). 본 회차의 상태 초기화가 그 행들을 치우는데, 그게 DELETE 면
    # undo 정리가 드레인 측정과 겹친다 — 그래서 run.sh 가 TRUNCATE 를 쓴다.
    #
    # 콜드 상태를 일부러 재려면 WARMUP_DURATION=0 으로 끈다. 배포나
    # 스케일아웃 중에 피크가 오는 상황이 그쪽이다.
    # 워밍업을 아예 끈 것과, 돌렸는데 부하가 안 나간 것은 다른 상태다.
    # ceiling-narrow.env 처럼 일부러 콜드를 재는 설정이 있어서 구분이 필요하다.
    warmed_by=off
    warmup_reqs=0
    warmup_capped=false
    warmup_above_threshold=false
    warmup_rounds=0
    if [ "${warmup_on}" = true ]; then
      warmed_by=none
      # 요청 수가 찰 때까지 반복한다. 길이만 고정하면 낮은 rate 에서는
      # 영원히 기준을 못 넘는다 — 30초 x 100 RPS 면 3,000건이다. db 모드는
      # 더 나쁘다. rate 를 아무리 올려도 앱이 초당 205건에서 포화하므로
      # 30초에 6,000건이 천장이다. 시간을 재는 대신 나간 양을 센다.
      warmup_status=0
      warmup_attempt=0
      while [ "${warmup_attempt}" -lt "${WARMUP_MAX_ROUNDS}" ]; do
        warmup_attempt=$(( warmup_attempt + 1 ))
        echo "==> 워밍업 ${warmup_attempt}/${WARMUP_MAX_ROUNDS} · ${WARMUP_DURATION} (결과는 버린다)"

        # 쓰기 전에 비운다. 뒤에서 비우면, 지난 스윕이 워밍업 직후에 죽었을 때
        # 남은 result.json 을 이번 첫 회차가 읽고 "데워졌다" 로 판단한다.
        rm -rf "${warmup_root:?}"
        mkdir -p "${warmup_root}"

        # 출력은 버리되 실패는 알린다. 조용히 넘어가면 워밍업이 매 회차 깨진 채로
        # 스윕이 끝나고, 그건 이 코드가 막으려는 상태(콜드 측정) 그대로다.
        #
        # 드레인 상한은 따로 짧게 준다. round_env 의 값을 물려받으면(ceiling.env 는
        # 1800) 워밍업이 드레이너를 밀었을 때 회차당 30분을 아무 출력 없이 선다.
        warmup_status=0
        env "${round_env[@]}" \
          "DURATION=${WARMUP_DURATION}" \
          "RESULTS_ROOT=${warmup_root}" \
          "DRAIN_CAP_SECONDS=${WARMUP_DRAIN_CAP_SECONDS}" \
          "${SCRIPT_DIR}/run.sh" >"${warmup_log}" 2>&1 || warmup_status=$?

        # 데워졌는지는 종료코드가 아니라 부하가 실제로 갔는지로 판단한다.
        # run.sh 는 어떤 불변식이 깨져도 1 로 끝나는데, 워밍업이 드레인 상한에
        # 걸리는 건(드레인미완) 흔하고 JVM 은 이미 데워진 상태다. 종료코드로
        # 정하면 그 회차가 warmed_by=none 으로 기록되어, 데운 회차를 콜드로
        # 라벨링한다 — 이 코드가 막으려는 실수의 반대 방향이다.
        # set -e 아래에서 find 가 0 이 아닌 상태로 끝나면 대입이 그대로 스윕을
        # 죽인다. 몇 시간짜리가 요약도 S3 업로드도 없이 끝난다.
        warmup_result="$(find "${warmup_root}" -name result.json -print -quit 2>/dev/null)" || warmup_result=""
        this_reqs=0
        if [ -n "${warmup_result}" ]; then
          this_reqs="$(jq -r '.k6.requests // 0' "${warmup_result}" 2>/dev/null)" || this_reqs=0
          warmup_capped="$(jq -r '.drain.capped // false' "${warmup_result}" 2>/dev/null)" || warmup_capped=false
        fi
        case "${this_reqs}" in ''|*[!0-9]*) this_reqs=0 ;; esac
        case "${warmup_capped}" in true) ;; *) warmup_capped=false ;; esac

        # 부하가 아예 안 나가면 더 돌려도 같다. 설정이나 앱 문제다.
        if [ "${this_reqs}" -eq 0 ]; then
          echo "경고: 워밍업에서 부하가 나가지 않았다(종료코드 ${warmup_status})." >&2
          tail -5 "${warmup_log}" >&2
          break
        fi

        # 부하가 실제로 나간 회차만 센다. 시도 횟수를 세면 부하 없이 죽은
        # 회차까지 포함돼 라벨이 없던 시간을 주장한다(30sx3 인데 60초만 나감).
        warmup_rounds=$(( warmup_rounds + 1 ))
        warmup_reqs=$(( warmup_reqs + this_reqs ))
        [ "${warmup_reqs}" -lt "${WARMUP_MIN_REQUESTS}" ] || { warmup_above_threshold=true; break; }
        echo "    누적 ${warmup_reqs}건 (기준 ${WARMUP_MIN_REQUESTS}). 더 돈다." >&2
      done

      if [ "${warmup_reqs}" -gt 0 ]; then
        # 기간은 그대로 남긴다. 값 집합 밖의 라벨을 새로 만들면 문서와 어긋나고,
        # "데워졌는가" 로 거르는 jq 필터가 그걸 웜으로 세거나 빠뜨린다.
        # 충분했는지는 warmup_above_threshold 가 따로 말한다.
        warmed_by="${WARMUP_DURATION}"
        [ "${warmup_rounds}" -le 1 ] || warmed_by="${WARMUP_DURATION}x${warmup_rounds}"
        [ "${warmup_status}" -eq 0 ] || \
          echo "워밍업이 ${warmup_status} 로 끝났지만 요청 ${warmup_reqs}건이 나갔다. 데워진 것으로 본다." >&2
        [ "${warmup_above_threshold}" = true ] || \
          echo "경고: ${WARMUP_MAX_ROUNDS}회를 돌고도 ${warmup_reqs}건뿐이다(기준 ${WARMUP_MIN_REQUESTS}). 덜 데워진 회차로 기록한다." >&2
      else
        echo "경고: 이 회차는 콜드로 기록한다." >&2
      fi

      # 워밍업이 드레인 상한에 걸렸으면 드레이너가 아직 일하는 중이다.
      # 본 회차의 상태 초기화가 그 위에서 돌고, 드레인 타이머도 한가하지 않은
      # 드레이너를 상대로 시작한다 — 드레이너 처리량 수치가 바로 그 타이머에서
      # 나오므로 그냥 넘어가면 안 된다. 더 기다리고, 결과에도 남긴다.
      # 얼마나 기다릴지는 모드가 정한다.
      #
      # redis 워밍업은 run.sh 가 드레인까지 기다려주므로 끝났을 때 비어 있다.
      # 예외는 그 대기가 상한에 걸린 경우고, 그때만 길게 잡는다.
      #
      # db 는 드레인 단계 자체가 없다(run.sh 는 MODE=redis 일 때만 기다린다).
      # 그래서 drain.capped 는 db 회차에서 항상 false 다 — 이걸로 분기하면
      # 정작 기다려야 할 모드가 짧은 쪽을 받는다.
      warmup_settle="${WARMUP_SETTLE_SECONDS}"
      warmup_settle_reason=""
      if [ "${mode}" = db ]; then
        warmup_settle="${WARMUP_DB_SETTLE_SECONDS}"
        warmup_settle_reason="db 는 워밍업에 드레인 대기가 없다"
      elif [ "${warmup_capped}" = true ]; then
        # 0 이면 곱해도 0 이라 경고만 찍고 안 기다리는 꼴이 된다. 바닥을 둔다.
        warmup_settle=$(( WARMUP_SETTLE_SECONDS * 6 ))
        [ "${warmup_settle}" -ge 30 ] || warmup_settle=30
        warmup_settle_reason="워밍업이 드레인 상한(${WARMUP_DRAIN_CAP_SECONDS}s)에 걸렸다"
      fi
      if [ -n "${warmup_settle_reason}" ]; then
        echo "${warmup_settle_reason}. ${warmup_settle}s 기다린다." >&2
        # 밀린 양을 빼주려는 게 아니다. 120초에 못 뺀 걸 30초에 뺄 리 없고,
        # 본 회차의 상태 초기화가 스트림과 오프셋을 어차피 지운다. 기다리는
        # 건 진행 중인 배치가 끝나라고 주는 시간이다. 남는 영향은 드레이너
        # 경합과 커진 테이블이고, 그건 결과의 warmup_drain_capped 로 남긴다.
        [ "${warmup_capped}" = false ] || \
          echo "      진행 중인 배치가 끝날 시간이다. 밀린 양은 상태 초기화가 지운다." >&2
      fi

      # 워밍업이 남긴 일이 끝나기를 기다린다.
      #
      # 재기동 직후에는 진행 중인 작업이 없었지만, 이제 본 회차가 워밍업
      # 바로 뒤에 붙는다. redis 모드는 run.sh 가 드레인을 기다려주므로
      # 비어 있지만, db 모드는 드레인 단계 자체가 없다 — 워밍업의 마지막
      # 트랜잭션들이 events 행 락을 쥔 채로 본 회차의 상태 초기화와
      # 첫 부하에 겹친다.
      sleep "${warmup_settle}"
    fi

    round_status=0
    # 데웠는지를 result.json 에 남긴다. 안 남기면 커밋된 결과만 보고
    # 콜드인지 웜인지 구분할 수 없다 — 이 저장소가 실제로 그래서 헤맸다.
    env "${round_env[@]}" \
      "WARMED_BY=${warmed_by}" \
      "WARMUP_REQUESTS=${warmup_reqs}" \
      "WARMUP_DRAIN_CAPPED=${warmup_capped}" \
      "WARMUP_ABOVE_THRESHOLD=${warmup_above_threshold}" \
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
printf '%-6s %6s %6s %6s %8s %8s %8s %8s %10s  %s\n' \
  mode batch delay rate 정원 승인 드레인 p95ms 워밍업 위반
# 이 회차 것만 센다. 같은 설정을 다시 돌리면 결과가 같은 디렉터리에 쌓이는데,
# 그걸 다 세면 위의 총계와 표가 어긋나고 어느 게 이번 것인지 알 수 없다.
find "${SWEEP_ROOT}" -name result.json -newermt "${sweep_start_local}" 2>/dev/null | sort | while read -r f; do
  # jq 가 깨진 파일에 실패하면 파이프라인이 0 이 아닌 상태를 내고, set -e 가
  # 여기서 스크립트를 끝낸다 — 아래 S3 업로드와 결과 경로 출력을 못 보고
  # 몇 시간짜리 스윕이 빈손으로 끝난다.
  # 데웠는지를 표에도 싣는다. 파일을 열어야만 알 수 있으면, 스윕이 끝난 자리에서
  # 표만 보고 "이건 웜 수치" 라고 착각한다 — 이 저장소가 실제로 그랬다.
  #
  # 길이만 찍으면 안 된다. 워밍업이 2초 만에 죽어 400건만 나가도 '30s' 로
  # 보이고, 낮은 rate 에서는 정상이어도 요청이 몇 천 건뿐이라 JIT 이 덜 오른다.
  # '30s/6k' 처럼 실제로 나간 요청 수를 붙여서 표가 스스로 말하게 한다.
  jq -r '[.mode, (.writer.batch_size|tostring), (.writer.delay_ms|tostring),
          (.load.rate|tostring), (.event.capacity|tostring), (.db.accepted|tostring),
          ((.drain.seconds|tostring) + "s"), (.k6.p95_ms|tostring|.[0:7]),
          ((.load.warmed_by // "?")
           + (if (.load.warmup_requests // 0) > 0
              then "/" + (if .load.warmup_requests >= 1000
                          then ((.load.warmup_requests / 1000) | floor | tostring) + "k"
                          else (.load.warmup_requests | tostring) end)
              else "" end)
           + (if .load.warmup_above_threshold == false and (.load.warmup_requests // 0) > 0
              then "?" else "" end)
           + (if (.load.warmup_drain_capped // false) then "!" else "" end)),
          .violations]
         | @tsv' "$f" 2>/dev/null \
    | awk -F'\t' '{printf "%-6s %6s %6s %6s %8s %8s %8s %8s %10s  %s\n",$1,$2,$3,$4,$5,$6,$7,$8,$9,$10}' \
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
