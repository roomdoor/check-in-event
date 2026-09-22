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

       버킷에는 회차가 접두사별로 쌓이고 destroy 할 때까지 남는다. 받을
       때는 반드시 이번에 돌린 접두사 하나만 지정할 것. results/ 를 통째로
       받으면 지난 스윕까지 딸려와 같은 결과가 두 번 커밋된다.

       fetch-results.sh 는 쓰지 말 것. 올릴 때 REMOTE_RESULTS 의 마지막
       디렉터리 이름을 버리고 results/ 바로 아래에 붓고, 내려받을 때는
       REMOTE_RESULTS 와 무관하게 results/ 접두사 전체를 가져온다. 버킷에
       이번 회차 말고 아무것도 없을 때만 맞는 스크립트다.

       BUCKET="$(terraform -chdir=infra output -raw results_bucket)"

       # 스윕이면 — sweep.sh 가 끝에 results/<config 이름>/ 으로 이미 올린다.
       # 내려받기만 하면 된다. CFG 는 이번에 돌린 config 이름으로 바꿀 것.
       CFG=compare
       aws s3 sync "s3://$BUCKET/results/$CFG/" "./loadtest/results/ec2/$CFG/"

       # 접두사를 틀리면 aws s3 sync 는 아무 말 없이 성공한다. 세어 볼 것 —
       # 0 이면 받은 게 없는 것이고, 그대로 destroy 하면 결과가 사라진다.
       find "./loadtest/results/ec2/$CFG" -name result.json | wc -l

       # 단발 회차면 run.sh 가 S3 로 올리지 않으므로 올리는 단계가 필요하다.
       # RUN 은 run.sh 가 마지막에 찍어준 디렉터리 이름이다.
       # C 호스트에서:
       RUN=redis-rate400-dup0.1-20260101-000000
       aws s3 sync /opt/check-in-event/loadtest/results/$RUN/ \
         "s3://$RESULTS_BUCKET/results/single/$RUN/"
       # 로컬에서:
       aws s3 sync "s3://$BUCKET/results/single/$RUN/" "./loadtest/results/ec2/$RUN/"

    4) 커밋한 뒤
       terraform -chdir=infra destroy

    주의: 측정 중에는 -var 값을 바꾸지 말 것. 인스턴스가 교체되고 디스크의
    측정 결과가 사라진다. 새 스크립트는 호스트에서
    git -C /opt/check-in-event pull 로 받는다.
  EOT
}
