output "connect" {
  description = "각 호스트 접속 명령 (SSH 키 불필요)"
  value       = module.bench.connect
}

output "instance_ids" {
  value = module.bench.instance_ids
}

output "region" {
  description = "scripts/fetch-results.sh 가 읽는다."
  value       = module.bench.region
}

output "results_bucket" {
  value = module.bench.results_bucket
}

output "support_private_ip" {
  description = "MySQL·Redis 가 뜬 호스트. run.sh 에 넘길 주소다."
  value       = module.bench.support_private_ip
}

output "db_password" {
  value     = module.bench.db_password
  sensitive = true
}

output "next_steps" {
  value = <<-EOT
    1) 부트스트랩 확인 (세 호스트 모두 /var/lib/bench-ready)
       ${module.bench.connect.load}
       ls /var/lib/bench-ready && tail /var/log/bench-bootstrap.log

    2) 측정 (C 호스트에서)
       sudo -i
       cd /opt/check-in-event

       # BASE_URL, SUT_INSTANCE_ID, AWS_REGION, RESULTS_BUCKET 은
       # /etc/profile.d/bench.sh 에 심어져 있다.
       # DB·Redis 는 B 호스트에 있으므로 주소를 따로 준다.
       export REDIS_HOST=${module.bench.support_private_ip}
       export MYSQL_HOST=${module.bench.support_private_ip}

       # MySQL root 비밀번호는 apply 마다 새로 생성된다. run.sh 기본값은
       # 'root' 라 이걸 안 주면 사전 점검에서 접속 실패로 멈춘다.
       export MYSQL_PASSWORD="$(aws ssm get-parameter --region ${module.bench.region} \
         --name /${var.name_prefix}/db-password --with-decryption \
         --query 'Parameter.Value' --output text)"

       # 한 판만:
       MODE=redis RATE=400 DURATION=1m CAPACITY=10000 ./loadtest/run.sh

       # 조합 스윕 (앱 재기동까지 알아서 한다):
       ./loadtest/sweep.sh loadtest/config/drainer.env

    3) 결과 회수 (로컬에서, destroy 전에 반드시)

       받는 경로는 ec2/ 아래로 둘 것. .gitignore 가 그 경로만 커밋을
       허용한다 — 로컬 회차와 섞이면 어느 쪽 수치였는지 알 수 없다.

       스윕과 단발 회차는 받는 방법이 다르다. sweep.sh 는 끝에 자기 결과를
       s3://<버킷>/results/<config 이름>/ 으로 이미 올린다. 그러니 스윕은
       내려받기만 하면 된다.

       여기에 fetch-results.sh 를 쓰면 안 된다. 그 스크립트는 호스트에서
       S3 로 올리는 단계부터 하는데, 올리는 자리가 results/ 바로 아래라
       sweep.sh 가 넣어둔 것과 겹친다. 같은 회차가 results/<run_id>/ 와
       results/<config>/<run_id>/ 양쪽에 생겨 두 번 커밋되고, 버킷에 남아
       있던 지난 스윕까지 딸려 내려온다.

       # 스윕이면 — 버킷에서 바로 내려받는다
       BUCKET="$(terraform -chdir=infra output -raw results_bucket)"
       aws s3 sync "s3://$BUCKET/results/compare/" ./loadtest/results/ec2/compare/

       # 단발 회차면 fetch-results.sh 를 쓴다. run.sh 는 S3 로 올리지 않으므로
       # 호스트에서 올리는 단계가 필요하다. REMOTE_RESULTS 에는 run.sh 가
       # 마지막에 찍어준 경로 하나만 줄 것 — results 디렉터리를 통째로 주면
       # 저장소에 커밋돼 clone 을 타고 호스트에 가 있는 지난 결과까지 다시
       # 올라왔다 내려오며 경로가 중첩된다.
       TF_DIR=infra \
       REMOTE_RESULTS=/opt/check-in-event/loadtest/results/<run_id> \
       DEST=./loadtest/results/ec2/<run_id> \
         <k6-bench-kit>/scripts/fetch-results.sh

    4) 커밋한 뒤
       terraform -chdir=infra destroy

    주의: 측정 중에는 -var 값을 바꾸지 말 것. 인스턴스가 교체되고 디스크의
    측정 결과가 사라진다. 새 스크립트는 호스트에서
    git -C /opt/check-in-event pull 로 받는다.
  EOT
}
