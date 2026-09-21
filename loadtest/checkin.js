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
const KEY_PREFIX = __ENV.KEY_PREFIX || "u";

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

// 모듈 스코프는 VU마다 따로 잡힌다. 이미 보낸 키를 들고 있다가 재사용한다.
let sentKeys = [];

function nextKey() {
  if (DUP_RATIO > 0 && sentKeys.length > 0 && Math.random() < DUP_RATIO) {
    dupSentCounter.add(1);
    return sentKeys[Math.floor(Math.random() * sentKeys.length)];
  }
  const key = `${KEY_PREFIX}-${__VU}-${__ITER}`;
  // 재사용 후보가 무한정 늘지 않게 앞쪽만 남긴다.
  if (sentKeys.length < 1000) {
    sentKeys.push(key);
  }
  return key;
}

export default function () {
  const payload = JSON.stringify({ participantKey: nextKey() });

  const res = http.post(`${BASE_URL}${PATH}`, payload, {
    headers: { "Content-Type": "application/json" },
  });

  check(res, {
    "status 200": (r) => r.status === 200,
  });

  if (res.status !== 200) {
    errorCounter.add(1);
  } else {
    // db 모드는 중복이어도 저장된 원래 행을 그대로 돌려준다 —
    // 응답만으로는 신규와 구분되지 않는다. duplicate 필드는 redis 모드에만 있다.
    const body = res.json();
    if (body && body.result === "ACCEPTED") {
      acceptedCounter.add(1);
    } else if (body && body.result === "REJECTED") {
      rejectedCounter.add(1);
    }
    if (body && body.duplicate === true) {
      duplicateCounter.add(1);
    }
  }

  sleep(SLEEP);
}
