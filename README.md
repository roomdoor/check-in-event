# check-in-event — 선착순 체크인, 동기 저장과 비동기 저장의 처리 한계 측정

Spring Boot 3.3 + Kotlin 기반의 선착순 체크인 서버.
정원이 정해진 이벤트에 사람이 몰릴 때 **앞에서부터 정원만큼만 받고 나머지는 거절한다.**

**목적**: 동일한 기능을 **2가지 저장 방식**으로 구현하고, 같은 부하에서 **무엇이 처리 한계를 정하는지** 실측한다.

| 방식 | 엔드포인트 | 승인 판정 | 저장 |
| --- | --- | --- | --- |
| **DB 락** | `POST /api/events/{id}/check-ins` | 행을 잠그고(`PESSIMISTIC_WRITE`) 정원 확인 | 요청 안에서 끝낸다 |
| **Redis** | `POST /api/redis/events/{id}/check-ins` | Lua 스크립트가 원자적으로 판정 | 스트림에 넣고 즉시 응답, 저장은 뒤에서 |

측정 환경: AWS 3호스트 — 앱(c7i.2xlarge), MySQL+Redis(m7i.xlarge), k6(c7i.2xlarge). 같은 AZ, `ap-northeast-2`.

---

## 요약

**동기 저장의 천장은 행 락이 정한다. 비동기는 그 자리를 응답 경로에서 빼버린다.**

| 방식 | 초당 저장 한계 | 800 RPS 결과 | 지연이 유지되는 한계 |
| --- | --- | --- | --- |
| **DB 락** | **205/s** | 12,244건 저장, p95 10,988ms | 100 RPS |
| **Redis** | **721/s 이상** (미발견) | 43,236건 저장, p95 3.3ms, 드레인 0초 | **800 RPS 에서도 안 꺾임** |

**같은 부하에서 3.5배를 저장한다.** 다만 이 배수는 천장끼리의 비교가 아니다 — Redis 쪽은 이번 부하로 한계에 닿지 않았다.

숫자보다 중요한 건 **저장이 응답 경로에 있느냐**다. DB 락은 모든 요청이 `events` 행 하나를 `PESSIMISTIC_WRITE` 로 잠그고 트랜잭션이 끝날 때까지 쥔다. 이미 직렬이므로 스레드를 늘려도 그 구간은 안 넓어진다. Redis 는 Lua 로 승인 여부만 정하고 `persisted: false` 로 답한 뒤, 저장은 `CheckInStreamWriter` 가 뒤에서 묶어서 한다.

**천장보다 먼저 지연이 무너진다.** DB 락은 초당 200건에서 이미 p95 가 1.25초다. 205/s 는 "언젠가 저장은 된다"는 값이지 서비스할 수 있는 값이 아니다.

> 정원을 부하보다 크게 둔 조건이다(정원 200,000). 거절은 저장하지 않으므로, 정원이 작으면 대부분이 거절이 되어 정작 재려던 저장 부하가 안 걸린다.

---

## 1. 동기 저장의 천장은 `events` 행 하나다

초당 요청을 두 배씩 올리며 실제로 저장된 행을 셌다.

| RPS | 저장 | 초당 | p95 | 버려진 이터레이션 |
| --- | --- | --- | --- | --- |
| 100 | 5,429 | 90 | 11.4ms | 0 |
| 200 | 10,619 | 177 | 1,251ms | 201 |
| 400 | 12,323 | **205** | 10,550ms | 10,578 |
| 800 | 12,244 | **204** | 10,988ms | 34,597 |

**400 과 800 이 같은 자리에 눕는다.** 부하를 두 배로 올려도 저장량이 안 늘고 지연만 늘어난다 — 넘친 요청이 처리량이 아니라 대기열이 된다.

이유는 구조에 있다. `CheckInService` 가 `findByIdForUpdate` 로 `events` 행을 잠그고, 그 락을 트랜잭션이 끝날 때까지 쥔다. 정원 확인·체크인 삽입·카운터 증가가 전부 그 안이다. 모든 요청이 같은 행을 노리므로 **이미 한 줄로 서 있고**, 205/s 는 그 직렬 구간이 1초에 몇 번 돌 수 있는지를 잰 값이다.

**쓸 수 있는 구간은 그보다 한참 아래다.** 100 RPS 에서 p95 11.4ms, 200 RPS 에서 1,251ms — 두 배 올리는 사이에 110배가 됐다. 대기열이 자라기 시작하는 지점이 100 과 200 사이다.

원본: [`loadtest/results/ec2/compare`](loadtest/results/ec2/compare)

---

## 2. 비동기는 응답 경로에서 저장을 뺀 것이다

같은 부하, 같은 정원, 드레이너는 batch 1600 / delay 100ms 로 고정했다.

| RPS | 저장 | 초당 | p95 | 드레인 |
| --- | --- | --- | --- | --- |
| 100 | 5,418 | 90 | 6.8ms | 0초 |
| 200 | 10,714 | 179 | 5.7ms | 0초 |
| 400 | 21,651 | 361 | 4.4ms | 0초 |
| 800 | 43,236 | **721** | 3.3ms | 0초 |

**전 구간에서 도착률을 그대로 따라간다.** 드레인이 전부 0초라는 건 부하가 끝난 시점에 Redis 에 밀린 게 없었다는 뜻이다 — 실시간으로 따라왔다.

**이 표에는 천장이 없다.** 800 에서도 안 꺾였으므로 어디가 한계인지 이 스윕은 답하지 않는다. 찾으려면 1,600·3,200 까지 올려야 한다.

**포화를 표현하는 방식이 다르다.**

| | 밀리면 | 호출자가 보는 것 |
| --- | --- | --- |
| DB 락 | 응답이 느려진다 | 10초 넘게 기다린다 |
| Redis | 원장이 뒤처진다 | 계속 3ms 로 답을 받는다 |

Redis 쪽에서 밀림은 지연이 아니라 **드레인 시간**으로 나타난다. 호출자는 승인 여부를 즉시 받지만, 그 결과가 MySQL 에 앉기까지는 시차가 있다. "승인됐다고 답했는데 조회하면 아직 없다"가 가능하다는 뜻이다.

어느 쪽이 나은지는 요구사항이 정한다 — "응답 시점에 저장까지 보장"이면 DB 락, "빨리 답하고 원장은 곧 따라온다"면 Redis 다.

---

## 3. 드레이너는 batch 보다 delay 가 정한다

Redis 방식의 실제 저장은 `CheckInStreamWriter` 가 한다. 저장 처리량은 `batch ÷ (저장시간 + delay)` 이고, `@Scheduled(fixedDelay)` 는 **작업이 끝난 뒤부터** 센다.

초당 720건이 들어올 때(800 RPS, 중복 10%) 조합별 드레인 시간:

| batch | delay | 드레인 | p95 |
| --- | --- | --- | --- |
| 200 | 500 | **54초** ← 기본값 | 3.1ms |
| 200 | 100 | 0초 | 2.9ms |
| 800 | 500 | 2초 | 3.1ms |
| 800 | 100 | 0초 | 2.9ms |
| 1600 | 500 | 3초 | 3.2ms |
| 1600 | 100 | 0초 | 3.0ms |

**기본값의 실제 처리량이 그 54초에서 나온다.** 1분 동안 43,200건이 들어왔고 빼는 데 54초가 더 걸렸으니 `54D = 43200 − 60D`, **D ≈ 379/s**. 배치 200 을 0.5초마다 도는 이론값 400/s 과 맞는다.

**delay 가 batch 보다 영향이 크다.** batch 를 8배 키워도 delay 500 이면 2~3초가 남는데, delay 만 100 으로 줄이면 기본 batch 로도 밀림이 사라진다. 저장이 빠르면 주기의 대부분이 그냥 기다리는 시간이기 때문이다.

그래서 **delay 가 더 싼 손잡이다.** batch 는 재시도 단위라 저장 하나가 실패하면 그 묶음 전체를 다시 하고, 크면 `events` 행 락도 더 오래 쥔다.

**응답 지연은 어느 조합에서도 안 변한다** (2.9~3.2ms). 엔드포인트가 저장 전에 답하므로, 드레이너 설정은 원장이 얼마나 뒤처지는지를 바꿀 뿐 호출자가 기다리는 시간은 안 바꾼다.

초당 180건(200 RPS)에서는 기본값(2초)을 뺀 다섯 조합이 전부 0초다. 기본 설정이 무너지는 건 그 사이 어딘가다.

원본: [`loadtest/results/ec2/drainer`](loadtest/results/ec2/drainer)

---

## 미해결

**Redis 방식의 천장을 못 찾았다.** 800 RPS 에서도 드레인이 0초라 한계가 그 위 어딘가라는 것만 안다. 1,600·3,200 으로 올려야 나온다.

**DB 락 쪽은 k6 가 부하를 다 못 보낸 회차가 있다.** 400·800 은 VU 2,000개를 다 쓰고 `Insufficient VUs` 를 냈다. 부하가 다 안 갔다는 뜻이므로 **그 두 회차의 p95 는 하한이지 측정값이 아니다.** 처리량(205/s)은 두 회차가 같은 값이라 읽어도 된다. 버려진 이터레이션 수(10,578 / 34,597)는 "DB 가 못 받았다"와 "k6 가 못 보냈다"가 섞인 값이다.

**200 회차도 깨끗하지 않다.** 커밋된 회차는 전부 `PRE_VUS=50` 으로 돌았다 — k6 가 나머지 VU 를 부하 도중에 만든다. 200 RPS 에서 버려진 201건은 DB 가 못 받아서가 아니라 그 준비 과정일 가능성이 크다(p95 1,251ms 면 250개면 충분한 구간이다). 저장량 자체는 도착률을 따라갔으므로 1 장의 "100 과 200 사이에서 무너진다"는 판단은 남지만, **그 201건을 포화 신호로 읽으면 안 된다.**

`compare.env` 는 그 뒤에 `PRE_VUS=2000` 으로 고쳤다. **지금 설정으로 다시 돌리면 이 표와 같은 값이 나오지 않는다** — 다음 회차부터 적용된다.

**Redis 의 p95 가 부하가 셀수록 낮아진다**(6.8 → 3.3ms). 방향이 반대다. 회차마다 앱을 재기동하므로 모든 회차가 콜드 JVM 에서 시작하고, 바쁜 회차가 JIT 을 더 끝낸다. **현상이지 결과가 아니다.**

**앱 기본값은 아직 200/500 이다.** 1600/100 이 낫다는 근거는 나왔지만, 그 조합의 천장을 모르는 채로 옮기지 않았다.

**정원 근처를 안 쟀다.** 두 스윕 모두 정원을 부하보다 훨씬 크게 뒀다. 실제 선착순은 대부분이 거절인 구간인데, 거절은 저장하지 않으므로 그쪽의 처리 특성은 이 수치로 알 수 없다.

**전부 n=1 이다.** 커밋된 21회차 모두 반복 없이 한 번씩 돌았다.

### 시스템 쪽 한계

측정이 아니라 서비스 자체에 남아 있는 것들이다.

- **Redis 스트림에 XTRIM 이 없다.** 거절 저장을 없애 증식 속도는 크게 줄었지만 여전히 무한히 자란다
- **Redis 가 죽으면** 아직 DB 로 안 넘어간 체크인이 사라진다. 복제본이 없다
- **Redis 모드에서 `카운터불일치` 검사는 사실상 통과가 보장돼 있다.** `syncAcceptedCount` 가 `run.sh` 의 비교 대상과 **같은 `COUNT(*)` 쿼리**로 `accepted_count` 를 쓰기 때문이다. 찢어진 쓰기는 잡지만 카운터 로직 결함은 못 잡는다 — 다만 그 자리는 `Redis-DB불일치` 가 덮는다. DB 모드는 `CheckInService` 가 `acceptedCount += 1` 로 따로 세므로 이 검사가 실제로 의미가 있다

---

## 방법론

### 숫자를 저장소에서 센다

k6 지표로는 실효 처리량을 못 잰다 — 거절도 빠른 `200` 을 받으므로 k6 에는 전부 성공으로 보인다. Redis 방식은 승인 응답조차 저장 전에 나간다.

그래서 MySQL 과 Redis 에서 직접 센다. 승인 행, `events.accepted_count`, Redis 카운터, 순번 해시, 중복 키를 각각 세고 **서로 맞는지** 회차마다 검사한다.

### 드레인

k6 는 `DURATION` 에서 멈추지만 Redis 방식은 그 시점에 아직 저장이 안 끝나 있다. `checkins:stream:offset` 이 스트림 끝에 닿을 때까지 기다린 뒤에 센다 — **오프셋은 배치가 실제로 저장에 성공해야만 전진한다.**

`sleep` 으로 때우면 Redis 방식이 실제보다 적게 나오고, **부하가 셀수록 많이 빠져 천장이 실제보다 낮아 보인다.** 추측하지 않는다.

### 검사하는 불변식

하나라도 깨지면 종료코드 1 이다.

| 위반 이름 | 조건 |
| --- | --- |
| `부하없음` / `저장없음` | k6 요청 > 0, 요청이 갔는데 저장 0건이 아닐 것 |
| `집계실패` | 집계 쿼리가 숫자를 돌려줬을 것 |
| `드레인미완` | 드레인이 상한에 걸리지 않았을 것 |
| `초과승인` / `초과승인_redis` / `초과승인_카운터` | 저장된 승인 행·Redis 카운터·`accepted_count` 각각 ≤ 정원 |
| `Redis내부불일치` | `count` == `SCARD users` |
| `순번누락` | `SCARD users` == `HLEN pos` |
| `Redis-DB불일치` | Redis 카운터 == 저장된 승인 행 |
| `카운터불일치` | `events.accepted_count` == 저장된 승인 행 |
| `중복행` | `(event_id, participant_key)` 중복 0 |
| `중복미발생` | `DUP_RATIO > 0` 이면 재사용이 실제로 나갔을 것 |

첫 줄이 제일 중요하다. **아무 일도 안 일어난 회차는 나머지 검사가 전부 0끼리 비교라 저절로 통과한다.** 앱이 요청마다 500을 뱉어도 "위반 없음" 이 나오던 것을 이 검사로 막는다.

### 회차가 실패해도 그 회차만 버린다

불변식 위반, 사전 점검 실패, 드레인 상한 — 어느 쪽이든 그 회차를 실패로 세고 다음으로 간다. 스윕이 도중에 "천장이다"라고 판단해서 남은 회차를 건너뛰지 않는다. 그 판단은 사람이 표를 보고 한다. 다만 **전 회차가 실패하면** 스윕 자체를 실패로 끝낸다 — 그건 설정이 틀린 것이다.

### 조건은 회차마다 기록한다

`result.json` 에 모드·부하·정원·드레이너 설정·VU 수와 함께 **어디에 대고 쟀는지**(`base_url`, `redis_host`, `mysql_host`)를 남긴다. 한 머신에서 돈 회차와 3호스트 회차를 나중에 구분할 수 있어야 하기 때문이다.

### 자동화

| 경로 | 용도 |
| --- | --- |
| `loadtest/run.sh` | 한 판. 초기화 → k6 → 드레인 → 집계 → 불변식 |
| `loadtest/sweep.sh` | 조합 스윕. 회차마다 앱을 그 설정으로 재기동한다 |
| `loadtest/config/*.env` | 측정 하나 = 파일 하나 |
| `loadtest/checkin.js` | k6 시나리오 |
| `infra/` | 측정용 AWS 3호스트 Terraform |

공통 인프라는 [`roomdoor/k6-bench-kit`](https://github.com/roomdoor/k6-bench-kit) 에 있다. 결과 회수 스크립트도 그쪽이다.

**스윕이 앱을 직접 재기동하는 이유가 있다.** 손으로 하면 앱 기동 인자와 `run.sh` 에 넘긴 `WRITER_*` 를 사람이 맞춰야 하는데, `run.sh` 는 그 값을 결과에 받아 적기만 하고 검증하지 않는다. 어긋나면 **결과 파일이 조용히 거짓말을 한다.**

---

## 설계에서 정한 것

### 거절은 저장하지 않는다

선착순은 정원보다 요청이 훨씬 많다. 거절까지 원장에 남기면 **쓰기의 대부분이 "떨어진 사람" 기록**이 된다. 400 RPS·정원 2,000 을 30초 준 회차에서 승인 2,000 대 거절 7,635 였다 — 원장에 남겼다면 쓰기의 79%가 거절이다([원본](loadtest/results/ec2/redis-rate400-dup0.2-20260922-010918)).

거절은 응답으로 알려주고 끝낸다. **두 방식 모두** 그렇게 맞췄다 — 한쪽만 바꾸면 서로 다른 양의 일을 하게 되어 처리량 비교가 다시 무의미해진다.

DB 경로는 저장된 행이 없으므로 응답의 `id` 가 `null` 이 된다. Redis 경로는 원래 `id` 를 주지 않는다(`position`·`duplicate`·`persisted` 를 준다).

```json
DB    {"id": null, "eventId": 1, "participantKey": "u-1", "result": "REJECTED", ...}
Redis {"eventId": 1, "participantKey": "u-1", "result": "REJECTED", "position": null, ...}
```

### Lua 를 쓰는 이유

정원 판정만이면 `INCR` 반환값으로 충분하다 — 그게 곧 순번이다. Lua 가 필요한 건 **여러 연산을 한 덩어리로 묶어야** 하기 때문이다.

```
SISMEMBER (중복 확인) → GET/비교 (정원) → INCR → SADD → HSET (순번) → XADD
```

중간에 끼어들면 "카운터는 올랐는데 집합엔 없는" 상태가 생긴다.

### 승인 인원은 세어서 맞춘다

`events.accepted_count` 는 배치 반환값으로 늘리지 않고, 저장된 행을 세서 덮어쓴다. 한 문장이라 읽기-쓰기 사이에 끼어들 틈이 없다.

```sql
update events e
   set e.accepted_count = (select count(*) from check_ins c
                            where c.event_id = e.id and c.accepted = 1)
 where e.id = ?
```

배치 반환값을 쓸 수 없는 이유가 있다. 데이터소스에 `rewriteBatchedStatements=true` 가 켜져 있어 드라이버가 배치를 다중행 INSERT 한 문장으로 합치고, 그러면 행별 건수를 알 수 없어 JDBC 규약대로 `SUCCESS_NO_INFO`(-2)를 돌려준다. 이걸 "삽입된 행"으로 세면 **항상 0** 이 된다. 실제로 그 버그가 있었다.

---

## 운영 참고

**방식 선택**

- **DB 락** — 응답 시점에 저장까지 끝나 있어야 하면 이쪽이다. 다만 초당 100건 언저리를 넘길 계획이면 안 된다. 205/s 는 천장이지 운영 구간이 아니다
- **Redis** — 초당 수백 건 이상이면 이쪽이다. 대신 "승인 응답을 받았는데 조회하면 아직 없다"는 구간을 받아들여야 한다

**드레이너 설정**

```yaml
checkin:
  redis:
    writer:
      batch-size: 200    # 기본값. 측정은 1600 까지 확인했다
      delay: 500         # 기본값. 100 이면 같은 batch 로도 밀리지 않는다
```

기본값은 초당 약 380건이다. 목표가 그보다 위면 **delay 부터 줄일 것** — batch 를 키우는 쪽은 효과가 작고, 재시도 단위와 락 점유 시간이 같이 커진다.

**정원은 Redis 와 DB 양쪽에 있다.** Lua 가 보는 카운터와 `events.accepted_count` 가 따로 관리되므로, 초기화 순서가 틀리면 둘이 어긋난 채로 시작한다. `run.sh` 가 회차마다 양쪽을 비교하는 이유다.

---

## 아키텍처

### 패키지 구조

```
src/main/kotlin/com/checkin/event/
├── event/                이벤트 생성·조회 (controller, service, repository, entity, dto)
└── checkin/
    ├── controller/       CheckInController (DB 락), CheckInRedisController
    ├── service/          CheckInService — events 행을 잠그고 요청 안에서 저장
    │                     CheckInServiceByRedis — Lua 판정 후 즉시 응답
    │                     CheckInStreamWriter — 스트림을 읽고 오프셋을 전진시킨다
    │                     CheckInStreamPersistService — 배치 삽입과 승인 인원 집계.
    │                       3 장의 "batch 는 재시도 단위" 가 가리키는 자리다
    ├── redis/            CheckInRedisStore — Lua 스크립트
    └── repository/       CheckInBatchRepository — 배치 저장, 승인 인원 집계

loadtest/                 run.sh, sweep.sh, checkin.js, config/
infra/                    측정용 Terraform (k6-bench-kit 을 module 로 쓴다)
```

### API

```
POST /api/events/{eventId}/check-ins          # DB 락
POST /api/redis/events/{eventId}/check-ins    # Redis

POST /api/events                              # 이벤트 생성 (정원 지정)
GET  /api/events/{eventId}
```

요청:
```json
{ "participantKey": "u-1001" }
```

DB 경로는 저장까지 끝내고 답한다. Redis 경로는 승인 여부와 순번을 즉시 주고 `persisted: false` 를 함께 보낸다 — 원장 반영은 그 뒤다.

---

## 실행

### AWS 에서 측정

```bash
# 로컬
terraform -chdir=infra init && terraform -chdir=infra apply
terraform -chdir=infra output next_steps

# 부하 호스트(C)에서 — 접속 명령은 output connect 에 있다
sudo -i
cd /opt/check-in-event
. /etc/profile.d/bench.sh
export REDIS_HOST=<B 호스트 사설 IP>
export MYSQL_HOST=<B 호스트 사설 IP>
export MYSQL_PASSWORD="$(aws ssm get-parameter --region "$AWS_REGION" \
  --name /checkin-bench/db-password --with-decryption \
  --query Parameter.Value --output text)"

MODE=redis RATE=400 DURATION=1m CAPACITY=10000 ./loadtest/run.sh   # 한 판
./loadtest/sweep.sh loadtest/config/compare.env                     # 스윕

# 다시 로컬에서 — destroy 전에 반드시
TF_DIR=infra \
REMOTE_RESULTS=/opt/check-in-event/loadtest/results/compare \
DEST=./loadtest/results/ec2/compare \
  <k6-bench-kit>/scripts/fetch-results.sh

terraform -chdir=infra destroy
```

> **`apply` 를 다시 돌릴 때 `-var` 값을 바꾸지 말 것.** 세 인스턴스 모두 `user_data_replace_on_change = true` 라, `repo_ref` 가 바뀌면 인스턴스가 **교체되고 디스크의 측정 결과가 같이 사라진다.**
>
> 새 스크립트는 호스트에서 `git -C /opt/check-in-event pull` 로 받는다.

정확한 명령은 `terraform output next_steps` 가 이번 apply 의 주소와 함께 찍어준다.

### 로컬에서 기동

```bash
docker compose up -d                     # MySQL + Redis
./gradlew bootRun

MODE=redis RATE=400 DURATION=20s CAPACITY=1000 DUP_RATIO=0.2 ./loadtest/run.sh
```

로컬은 **하네스가 도는지 보는 용도다.** 성능 측정에는 쓰지 않는다 — 앱·MySQL·Redis·k6 가 한 머신에 있으면 무엇이 병목인지 구분되지 않는다. `.gitignore` 가 로컬 회차를 커밋에서 막는 이유다.

| 변수 | 기본값 | 뜻 |
| --- | --- | --- |
| `MODE` | `db` | `db` 또는 `redis` |
| `RATE` | 2000 | 초당 요청 수 |
| `DURATION` | 1m | 부하 시간 |
| `CAPACITY` | 10000 | 이벤트 정원 |
| `DUP_RATIO` | 0 | 같은 참가자가 다시 누르는 비율. `0`, `1`, 소수점 둘째 자리까지 |
| `PRE_VUS` / `MAX_VUS` | 50 / 200 | k6 VU 수. 부족하면 도착률을 못 맞추고 이터레이션을 버린다 |
| `DRAIN_CAP_SECONDS` | 600 | 드레인 대기 상한 |
| `WRITER_BATCH_SIZE` / `WRITER_DELAY_MS` | 200 / 500 | 앱 기동 인자와 같게 줄 것. 결과에 기록만 한다 |
| `BASE_URL` | `http://localhost:8080` | |

결과는 `loadtest/results/<run_id>/result.json` 에 조건과 함께 남는다.

### 필요한 도구

**k6, jq** (없으면 `run.sh` 가 시작 전에 멈춘다). 원격 MySQL·Redis 를 볼 때는 `mysql`·`redis-cli` 클라이언트도 있어야 한다 — 없으면 로컬 컨테이너를 보게 되므로 `run.sh` 가 그것도 막는다.

AWS 측정에는 Terraform, AWS CLI 가 추가로 필요하다.

---

## Tech Stack

**Backend**: Kotlin · Spring Boot 3.3 · JPA (Hibernate `ddl-auto: update`) · MySQL 8 · Redis 7.2 (Lua + Stream)
**측정**: k6 · Terraform · AWS (EC2 · SSM · S3)
**Build**: Gradle (Kotlin DSL) · JDK 17

빌드와 실행 세부는 [`AGENTS.md`](AGENTS.md). Gradle 데몬은 JDK 17 에 고정돼 있다.

---

## 결과 디렉터리

`loadtest/results/ec2/compare` — 1 장과 2 장의 모든 수치. AWS 3호스트 실측 8회차.

`loadtest/results/ec2/drainer` — 3 장의 모든 수치. AWS 3호스트 실측 12회차.

`loadtest/results/ec2/redis-rate400-dup0.2-20260922-010918` — 스윕 자동화 이전의 단발 회차 하나. "거절은 저장하지 않는다" 의 비율이 여기서 나온다. `result.json` 이 옛 형식이라 **어디에 대고 쟀는지(`where`)가 없다** — 아래 "조건은 회차마다 기록한다" 는 그 뒤에 넣은 것이다.

**로컬 회차는 커밋하지 않는다.** 앱·MySQL·Redis·k6 가 한 머신에 있으면 무엇이 병목인지 구분되지 않아 수치로 쓸 수 없다. `.gitignore` 가 `ec2/` 아래만 커밋을 허용한다.

### 예전 수치를 버린 이유

이전 README 에 이런 표가 있었다.

```
2000 RPS:  DB Lock 505.82 RPS  vs  Redis 1,987.08 RPS  → 3.9배
```

**두 숫자의 단위가 다르다.** DB 락의 505 는 **저장까지 끝낸** 건수고, Redis 의 1,987 은 **접수만 한** 건수다. 응답에 `persisted: false` 가 찍혀 나간다. 즉 "3.9배" 는 **"접수만 하면 당연히 빠르다"** 를 잰 것이다.

그리고 측정 환경이 로컬 PC 한 대였다. **선착순에서 정작 물어야 할 것도 안 쟀다** — 정원을 정확히 지켰는가, 중복이 뚫렸는가. 지연 수치만 봐서는 알 수 없다.

그래서 측정 도구부터 다시 만들었다. 지금 표의 3.5배는 **양쪽 다 저장된 행을 센 값**이고, 회차마다 정원과 중복을 검사해 통과한 것만 남긴 것이다.
