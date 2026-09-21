import http from "k6/http";
import { check, sleep } from "k6";
import { Counter } from "k6/metrics";

const BASE_URL = __ENV.BASE_URL || "http://localhost:8080";
const EVENT_ID = __ENV.EVENT_ID || "8";
const MODE = __ENV.MODE || "db"; // db | redis
const DURATION = __ENV.DURATION || "1m";
const SLEEP = Number(__ENV.SLEEP || "0");
const RATE = Number(__ENV.RATE || "2000");
const TIME_UNIT = __ENV.TIME_UNIT || "1s";
const PRE_VUS = Number(__ENV.PRE_VUS || "50");
const MAX_VUS = Number(__ENV.MAX_VUS || "200");

// 같은 참가자가 다시 누르는 비율. 0이면 전원이 서로 다른 사람이라
// 중복 차단 경로(Lua의 SISMEMBER, DB의 유니크 제약)가 한 번도 안 걸린다.
const DUP_RATIO = Number(__ENV.DUP_RATIO || "0");

// 회차마다 달라야 한다. 고정값이면 두 번째 실행이 같은 키를 다시 보내고,
// event:{id}:users 에 이미 다 들어있으므로 전부 중복 분기로 빠진다 —
// XADD 도 DB 쓰기도 없이 지연만 0에 가깝게 나와서, 아무것도 안 재고
// 좋은 숫자를 보고하게 된다. run.sh 는 회차 id 를 넘겨주고, 맨손으로
// k6 를 돌릴 때는 이 기본값이 그 역할을 한다.
const KEY_PREFIX = __ENV.KEY_PREFIX || `u${Date.now()}`;

const PATH = MODE === "redis"
  ? `/api/redis/events/${EVENT_ID}/check-ins`
  : `/api/events/${EVENT_ID}/check-ins`;

// 집계는 DB/Redis에서 하는 게 정답이다. 이 카운터는 회차가 도는 동안
// 분포를 눈으로 보기 위한 것이고, 판정 근거로 쓰지 않는다.
const acceptedCounter = new Counter("checkin_accepted");
const rejectedCounter = new Counter("checkin_rejected");
const duplicateCounter = new Counter("checkin_duplicate_flagged");
const dupSentCounter = new Counter("checkin_duplicate_sent");
const errorCounter = new Counter("checkin_error");

export const options = {
  scenarios: {
    fixed_rate: {
      executor: "constant-arrival-rate",
      rate: RATE,
      timeUnit: TIME_UNIT,
      duration: DURATION,
      preAllocatedVUs: PRE_VUS,
      maxVUs: MAX_VUS,
    },
  },
};

// 모듈 스코프는 VU마다 따로 잡힌다. 승인된 키만 들고 있다가 재사용한다.
//
// 거부된 키를 넣으면 안 된다. 거부자는 event:{id}:users 집합에 안 들어가므로,
// 다시 보내도 Lua 의 SISMEMBER 중복 분기가 아니라 정원초과 분기를 탄다.
// 정원보다 부하가 훨씬 큰 회차에서는 거의 전부가 거부라, 중복을 보낸다고
// 믿으면서 실제로는 중복 경로를 한 번도 안 건드리게 된다.
let acceptedKeys = [];

// 재사용해서 보낸 키인지 여부를 같이 돌려준다. db 모드는 중복이어도 저장된
// 행을 그대로 주기 때문에 응답만으로는 구분이 안 되고, 그걸 다시 기억하면
// 같은 키 몇 개가 배열을 채워 중복 트래픽이 소수 참가자에게 쏠린다.
function nextKey() {
  if (DUP_RATIO > 0 && acceptedKeys.length > 0 && Math.random() < DUP_RATIO) {
    dupSentCounter.add(1);
    return { key: acceptedKeys[Math.floor(Math.random() * acceptedKeys.length)], reused: true };
  }
  return { key: `${KEY_PREFIX}-${__VU}-${__ITER}`, reused: false };
}

function rememberIfAccepted(key, reused, body) {
  if (reused) return;
  // 재사용 후보가 무한정 늘지 않게 앞쪽만 남긴다.
  if (acceptedKeys.length >= 1000) return;
  if (!body || body.result !== "ACCEPTED") return;
  if (body.duplicate === true) return;
  acceptedKeys.push(key);
}

export default function () {
  const { key, reused } = nextKey();
  const payload = JSON.stringify({ participantKey: key });

  const res = http.post(`${BASE_URL}${PATH}`, payload, {
    headers: { "Content-Type": "application/json" },
  });

  check(res, {
    "status 200": (r) => r.status === 200,
  });

  if (res.status !== 200) {
    errorCounter.add(1);
    sleep(SLEEP);
    return;
  }

  // db 모드는 중복이어도 저장된 원래 행을 그대로 돌려준다 —
  // 응답만으로는 신규와 구분되지 않는다. duplicate 필드는 redis 모드에만 있다.
  const body = res.json();
  if (body && body.duplicate === true) {
    // redis 모드는 중복에도 result=ACCEPTED 를 준다(CheckInRedisStore 가
    // accepted = 승인 or 중복). 여기서 걸러내지 않으면 같은 사람을 여러 번
    // 승인으로 세어, 정원 1만짜리에서 승인 4만 같은 숫자가 나온다.
    duplicateCounter.add(1);
  } else if (body && body.result === "ACCEPTED") {
    acceptedCounter.add(1);
  } else if (body && body.result === "REJECTED") {
    rejectedCounter.add(1);
  }

  rememberIfAccepted(key, reused, body);
  sleep(SLEEP);
}
