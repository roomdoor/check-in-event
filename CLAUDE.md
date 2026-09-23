# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

선착순 체크인 서버(Kotlin + Spring Boot 3.3). 같은 기능을 **DB 락**(`CheckInService`, `events` 행 `PESSIMISTIC_WRITE`)과 **Redis**(`CheckInServiceByRedis` → `CheckInRedisStore` 의 Lua + Stream, `CheckInStreamWriter` 가 DB 로 배치 저장) 두 방식으로 만들고 k6 로 처리 한계를 비교한다.
측정 결과·해석·실행 절차는 `README.md` 를 따른다.

@AGENTS.md

## 함정

- 테스트는 `@SpringBootTest` `contextLoads` 하나뿐이고 테스트용 설정이 없어 `application.yml` 의 localhost MySQL 이 떠 있어야 통과한다(`docker compose up -d`, CI 는 MySQL·Redis 서비스 컨테이너).
- `bootJar` 는 `build/libs/app.jar` 고정 이름이고 `Dockerfile` 이 이 경로를 COPY 한다. 이름을 바꾸지 말 것.
- **거절은 두 경로 모두 저장하지 않는다.** 한쪽만 바꾸면 처리량 비교가 성립하지 않는다. Redis 경로의 `events.accepted_count` 는 배치 반환값이 아니라
  `CheckInBatchRepository.syncAcceptedCount` 가 `COUNT(*)` 로 덮어쓴다(`rewriteBatchedStatements=true` 라 반환값이 -2).
- **`loadtest/run.sh` 는 대상 MySQL·Redis 를 전역으로 비운다**(스트림·offset·`event:*` 키, `TRUNCATE check_ins`). 쓰는 데이터가 있는 DB 에 돌리지 말고, 두 개를 동시에 돌리지 말 것.
  불변식 판정은 DB·Redis 집계가 중심이지만 일부 검사와 거절 수는 k6 지표(`checkin.js` 의 Counter)를 쓴다. 지표 이름을 바꾸면 `run.sh` 도 같이 고친다.
- `sweep.sh` 는 EC2 부하 호스트 전용이다. 필요한 환경변수는 스크립트 헤더와 `terraform -chdir=infra output next_steps` 를 따른다.
- 로컬 측정은 하네스가 도는지 확인하는 용도다. 커밋된 결과 중 데워진 상태로 잰 것은 `warmup/` 뿐이라 나머지를 정상 상태 수치로 인용하지 말 것(README "결과 디렉터리").

## 인프라 (`infra/`)

- **x86 전용.** 이미지는 `linux/amd64` 단일, AMI 는 x86_64 다. arm64·멀티아치를 추가하지 말 것 — 에뮬레이션이 측정값을 오염시킨다.
- 앱 호스트는 부트스트랩 때 한 번만 이미지를 pull 한다. `sweep.sh` 의 재기동은 새로 pull 하지 않으므로, main 에 올린 새 `latest` 를 재려면 호스트에서 직접 pull 해야 한다.
- `user_data_replace_on_change = true` 라 재 `apply` 때 `-var` 를 바꾸면 인스턴스가 교체되고 결과가 사라진다. destroy·재 apply 전에 결과를 먼저 회수한다.
- `terraform.tfstate`·`tfplan` 에는 DB 비밀번호가 평문으로 들어간다. 커밋하지 않는다(`infra/.gitignore`).
