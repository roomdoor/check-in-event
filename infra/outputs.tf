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

       REMOTE_RESULTS 는 이번에 돌린 것 하나만 가리킬 것. 그 마지막
       디렉터리 이름이 버킷 안에서 이번 회차가 들어앉을 자리가 되고,
       받을 때도 같은 자리만 본다. results 디렉터리를 통째로 주면 저장소에
       커밋돼 clone 을 타고 호스트에 가 있는 지난 결과까지 다시 올라간다.

       # 스윕이면 — config 이름이 그대로 자리 이름이 된다
       TF_DIR=infra \
       REMOTE_RESULTS=/opt/check-in-event/loadtest/results/compare \
       DEST=./loadtest/results/ec2/compare \
         <k6-bench-kit>/scripts/fetch-results.sh

       # 단발 회차면 run.sh 가 마지막에 찍어준 디렉터리 이름을 그대로 쓴다
       TF_DIR=infra \
       REMOTE_RESULTS=/opt/check-in-event/loadtest/results/<run_id> \
       DEST=./loadtest/results/ec2/<run_id> \
         <k6-bench-kit>/scripts/fetch-results.sh

       빈 자리를 가리키면 스크립트가 멈추고 버킷에 실제로 있는 자리들을
       보여준다. 0개를 받아놓고 정상으로 보인 채 destroy 로 넘어가는 일은
       없다(kit v0.1.5).

    4) 커밋한 뒤
       terraform -chdir=infra destroy

    주의: 측정 중에는 -var 값을 바꾸지 말 것. 인스턴스가 교체되고 디스크의
    측정 결과가 사라진다. 새 스크립트는 호스트에서
    git -C /opt/check-in-event pull 로 받는다.
  EOT
}
