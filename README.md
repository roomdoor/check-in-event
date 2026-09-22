# check-in-event

선착순 이벤트 체크인 서버. 정원이 정해진 이벤트에 사람이 몰릴 때,
**앞에서부터 정원만큼만 받고 나머지는 거절하는 것**을 어떻게 구현하느냐에 따라
처리량이 어떻게 달라지는지 비교한다.

같은 기능을 두 방식으로 만들어두고 같은 부하를 준다.

| 방식 | 엔드포인트 | 승인 판정 | 저장 |
| --- | --- | --- | --- |
| **DB 락** | `POST /api/events/{id}/check-ins` | 행을 잠그고(`PESSIMISTIC_WRITE`) 정원 확인 | 요청 안에서 끝낸다 |
| **Redis** | `POST /api/redis/events/{id}/check-ins` | Lua 스크립트가 원자적으로 판정 | 스트림에 넣고 즉시 응답, 저장은 뒤에서 |

---

## ⚠️ 이전 측정 결과는 쓰지 않는다

예전 README 에 이런 표가 있었다.

```
2000 RPS:  DB Lock 505.82 RPS  vs  Redis 1,987.08 RPS  → 3.9배
```

**두 숫자의 단위가 다르다.** 비교가 성립하지 않는다.

- DB 락의 505 는 **저장까지 끝낸** 건수다
- Redis 의 1,987 은 **접수만 한** 건수다. 응답에 `persisted: false` 가 찍혀 나간다

Redis 방식의 실제 저장은 뒤에서 도는 `CheckInStreamWriter` 가 한다. 그쪽 한계는
**배치 200건 / 0.5초 = 초당 400건**이고, `@Scheduled(fixedDelay)` 는 작업이
끝난 뒤부터 세므로 밀릴수록 더 느려진다. 2,000건씩 들어오면 계속 쌓인다.

즉 "3.9배" 는 **"접수만 하면 당연히 빠르다"** 를 잰 것이다.

그리고 측정 환경이 `Local PC` 였다. 앱·MySQL·Redis·k6 가 한 머신에 있으면
무엇이 병목인지 구분되지 않는다. k6 가 CPU 를 먹으면 앱이 느려지고 그게 다시
k6 지표로 돌아온다.

**더 중요한 건, 선착순에서 정작 물어야 할 것을 안 쟀다는 점이다** —
정원을 정확히 지켰는가, 중복이 뚫렸는가. 지연 수치만 봐서는 알 수 없다.

그래서 측정 도구부터 다시 만들었다. 새 수치는 AWS 3호스트에서 재고 나서 채운다.

---

## 측정 방법

`loadtest/run.sh` 가 한 판을 끝까지 관리한다. k6 를 직접 돌리지 않는다.

```
상태 초기화 → 이벤트 생성 → k6 → 드레인 대기 → 저장소에서 집계 → 불변식 검사
```

**k6 지표로 판정하지 않는다.** k6 는 요청을 보낸 쪽만 안다.
거절도 빠른 200 을 받으므로 k6 에는 전부 성공으로 보인다.
진실은 MySQL 과 Redis 에서 직접 센다.

**드레인은 추측하지 않는다.** `checkins:stream:offset` 이 스트림 끝에 닿을
때까지 기다린다 — 오프셋은 배치가 실제로 저장에 성공해야만 전진한다.
`sleep` 으로 때우면 Redis 방식이 실제보다 적게 나온다.

### 검사하는 불변식

하나라도 깨지면 종료코드 1 이다.

| 항목 | 조건 |
| --- | --- |
| 부하 도달 | k6 요청 > 0, 요청이 갔는데 저장 0건이 아닐 것 |
| 드레인 완료 | 상한에 걸리지 않았을 것 |
| 초과 승인 | 저장된 승인 행 ≤ 정원, Redis 카운터 ≤ 정원 |
| Redis 내부 정합 | `count` == `SCARD users` == `HLEN pos` |
| Redis–DB 일치 | Redis 카운터 == 저장된 승인 행 |
| 카운터 정합 | `events.accepted_count` == 저장된 승인 행 |
| 중복 행 | `(event_id, participant_key)` 중복 0 |
| 중복 발생 | `DUP_RATIO > 0` 이면 재사용이 실제로 나갔을 것 |

첫 줄이 제일 중요하다. **아무 일도 안 일어난 회차는 나머지 검사가 전부
0끼리 비교라 저절로 통과한다.** 앱이 요청마다 500을 뱉어도 "위반 없음" 이
나오던 것을 이 검사로 막는다.

### 실행

```bash
docker compose up -d                     # MySQL + Redis
./gradlew bootRun                        # 또는 컨테이너로

MODE=redis RATE=400 DURATION=20s CAPACITY=1000 DUP_RATIO=0.2 ./loadtest/run.sh
```

| 변수 | 뜻 |
| --- | --- |
| `MODE` | `db` 또는 `redis` |
| `RATE` | 초당 요청 수 |
| `CAPACITY` | 이벤트 정원 |
| `DUP_RATIO` | 같은 참가자가 다시 누르는 비율 (0~1) |
| `WRITER_BATCH_SIZE`, `WRITER_DELAY_MS` | 앱 기동 인자와 같게 줄 것. 결과에 기록만 한다 |

결과는 `loadtest/results/<run_id>/result.json` 에 조건과 함께 남는다.

---

## 설계에서 정한 것

### 거절은 저장하지 않는다

선착순은 정원보다 요청이 훨씬 많다. 거절까지 원장에 남기면 **쓰기의 대부분이
"떨어진 사람" 기록**이 된다. 400 RPS·정원 1,000 에서 승인 1,000 대 거절 5,384 였다.

거절은 응답으로 알려주고 끝낸다. **두 방식 모두** 그렇게 맞췄다 — 한쪽만
바꾸면 서로 다른 양의 일을 하게 되어 처리량 비교가 다시 무의미해진다.

거절된 응답은 저장된 행이 없으므로 `id` 가 `null` 이다.

```json
{"id": null, "eventId": 1, "participantKey": "u-1", "result": "REJECTED", ...}
```

### Lua 를 쓰는 이유

정원 판정만이면 `INCR` 반환값으로 충분하다 — 그게 곧 순번이다. Lua 가 필요한
건 **여러 연산을 한 덩어리로 묶어야** 하기 때문이다.

```
SISMEMBER (중복 확인) → GET/비교 (정원) → INCR → SADD → HSET (순번) → XADD
```

중간에 끼어들면 "카운터는 올랐는데 집합엔 없는" 상태가 생긴다.

### 승인 인원은 세어서 맞춘다

`events.accepted_count` 는 배치 반환값으로 늘리지 않고, 저장된 행을 세서
덮어쓴다. 한 문장이라 읽기-쓰기 사이에 끼어들 틈이 없다.

```sql
update events e
   set e.accepted_count = (select count(*) from check_ins c
                            where c.event_id = e.id and c.accepted = 1)
 where e.id = ?
```

배치 반환값을 쓸 수 없는 이유가 있다. 데이터소스에 `rewriteBatchedStatements=true`
가 켜져 있어 드라이버가 배치를 다중행 INSERT 한 문장으로 합치고, 그러면 행별
건수를 알 수 없어 JDBC 규약대로 `SUCCESS_NO_INFO`(-2)를 돌려준다. 이걸 "삽입된
행"으로 세면 **항상 0** 이 된다. 실제로 그 버그가 있었다.

---

## 알려진 한계

- **아직 AWS 에서 재지 않았다.** 이 저장소의 수치는 전부 로컬이고,
  측정값이 아니라 도구가 동작하는지 확인한 것이다
- **Redis 스트림에 XTRIM 이 없다.** 거절 저장을 없애 증식 속도는 크게 줄었지만
  여전히 무한히 자란다
- **`카운터불일치` 검사가 앱과 같은 쿼리를 비교한다.** 찢어진 쓰기는 잡지만
  카운터 로직 결함은 못 잡는다. Redis 모드는 `Redis-DB불일치` 가 그 자리를
  덮지만 DB 모드는 덮는 검사가 없다
- **Redis 가 죽으면** 아직 DB 로 안 넘어간 체크인이 사라진다. 복제본이 없다

---

## 기술

Kotlin · Spring Boot 3.3 · MySQL 8 · Redis 7.2 (Lua + Stream) · k6 · JDK 17

```
src/main/kotlin/com/checkin/event/
├── event/          이벤트 생성·조회
├── checkin/
│   ├── service/    CheckInService(DB 락), CheckInServiceByRedis, StreamWriter
│   ├── redis/      CheckInRedisStore — Lua 스크립트
│   └── repository/ 배치 저장, 승인 인원 집계
loadtest/           run.sh(오케스트레이터), checkin.js(k6 시나리오)
```

빌드와 실행은 [`AGENTS.md`](AGENTS.md) 참고. Gradle 데몬은 JDK 17 에 고정돼 있다.
