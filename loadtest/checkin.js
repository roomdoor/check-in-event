import http from "k6/http";
import { check, sleep } from "k6";

const BASE_URL = __ENV.BASE_URL || "http://localhost:8080";
const EVENT_ID = __ENV.EVENT_ID || "8";
const MODE = __ENV.MODE || "db"; // db | redis
const VUS = Number(__ENV.VUS || "50");
const DURATION = __ENV.DURATION || "1m";
const SLEEP = Number(__ENV.SLEEP || "0");
const RATE = Number(__ENV.RATE || "2000");
const TIME_UNIT = __ENV.TIME_UNIT || "1s";
const PRE_VUS = Number(__ENV.PRE_VUS || "50");
const MAX_VUS = Number(__ENV.MAX_VUS || "200");

const PATH = MODE === "redis"
  ? `/api/redis/events/${EVENT_ID}/check-ins`
  : `/api/events/${EVENT_ID}/check-ins`;

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

export default function () {
  const userId = `user-${__VU}-${__ITER}-${Date.now()}`;
  const payload = JSON.stringify({ participantKey: userId });

  const res = http.post(`${BASE_URL}${PATH}`, payload, {
    headers: { "Content-Type": "application/json" },
  });

  check(res, {
    "status 200": (r) => r.status === 200,
  });

  sleep(SLEEP);
}
