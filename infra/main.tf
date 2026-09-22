terraform {
  required_version = ">= 1.6"
}

# 3호스트 뼈대는 k6-bench-kit 에서 온다 — VPC, 단일 AZ 고정, SSM, 결과 버킷,
# 부하 호스트 부트스트랩. 이 파일은 이 프로젝트가 무엇을 띄우는지만 정한다.
#
#   A (sut)     check-in-event 앱
#   B (support) MySQL + Redis
#   C (load)    k6 + loadtest/run.sh
module "bench" {
  # kit 이 private 이라 SSH 로 받는다. terraform init 이 로컬에서 도는 것이므로
  # EC2 에는 이 접근 권한이 필요 없다.
  #
  # 태그로 고정한다. ref=main 으로 두면 몇 주 뒤 apply 가 다른 모듈을 받아오고,
  # 그러면 같은 코드로 같은 인프라가 나온다는 보장이 사라진다.
  source = "git::ssh://git@github.com/roomdoor/k6-bench-kit.git//terraform?ref=v0.1.1"

  name_prefix = var.name_prefix
  region      = var.region

  repo_url = "https://github.com/roomdoor/check-in-event.git"
  repo_ref = var.repo_ref
  repo_dir = "/opt/check-in-event"

  # 없으면 부트스트랩이 멈춘다. 측정을 시작하고 나서 스크립트가 없는 걸 알면
  # 인스턴스를 다시 만들어야 한다.
  bench_scripts = ["loadtest/run.sh"]

  sut_port = 8080

  support_ports = [
    { from = 3306, to = 3306, description = "mysql" },
    { from = 6379, to = 6379, description = "redis" },
  ]

  sut_user_data_template = "${path.module}/templates/app.sh.tftpl"
  sut_user_data_vars = {
    image   = var.app_image
    db_name = var.db_name
  }

  support_user_data_template = "${path.module}/templates/deps.sh.tftpl"
  support_user_data_vars = {
    db_name = var.db_name
  }

  # support_host, region, db_param 은 모듈이 자동으로 넘겨준다 —
  # Terraform 이 만들기 전에는 알 수 없는 값들이다.

  sut_instance_type     = var.sut_instance_type
  support_instance_type = var.support_instance_type
  load_instance_type    = var.load_instance_type

  tags = {
    Project   = var.name_prefix
    Ephemeral = "true"
  }
}
