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

       MODE=redis RATE=400 DURATION=1m CAPACITY=10000 ./loadtest/run.sh

    3) 결과 회수 (로컬에서, destroy 전에 반드시)
       TF_DIR=infra \
       REMOTE_RESULTS=/opt/check-in-event/loadtest/results \
       DEST=./loadtest/results \
         <k6-bench-kit>/scripts/fetch-results.sh

    4) 커밋한 뒤
       terraform -chdir=infra destroy

    주의: 측정 중에는 -var 값을 바꾸지 말 것. 인스턴스가 교체되고 디스크의
    측정 결과가 사라진다. 새 스크립트는 호스트에서
    git -C /opt/check-in-event pull 로 받는다.
  EOT
}
