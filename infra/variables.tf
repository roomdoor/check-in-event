variable "name_prefix" {
  description = "생성되는 모든 리소스 이름 접두어. 비용 추적에도 쓰인다."
  type        = string
  default     = "checkin-bench"
}

variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "app_image" {
  description = "측정 대상 이미지. GHCR 패키지가 public 이어야 인스턴스가 받을 수 있다."
  type        = string
  default     = "ghcr.io/roomdoor/check-in-event:latest"
}

variable "db_name" {
  description = "application.yml 의 데이터베이스 이름과 같아야 한다."
  type        = string
  default     = "checkin_event"
}

variable "repo_ref" {
  description = <<-EOT
    C 호스트가 클론할 브랜치/태그. loadtest/run.sh 가 여기서 온다.

    최초 apply 에서만 정하고 그 뒤로는 바꾸지 말 것. 세 인스턴스 모두
    user_data_replace_on_change = true 라, 값이 바뀌면 인스턴스가 교체되고
    디스크의 측정 결과가 사라진다. 새 스크립트는 호스트에서
    git -C /opt/check-in-event pull 로 받는다.
  EOT
  type        = string
  default     = "main"
}

# 기본 인스턴스 타입은 kit 값(c7i.2xlarge / m7i.xlarge / c7i.2xlarge)을 그대로
# 쓴다. 이 서비스는 요청당 일이 적어서 더 작아도 될 수 있지만, 첫 측정에서
# 무엇이 천장인지 모르는 채로 줄이면 인스턴스가 천장이 된다. 한 번 재보고 줄인다.
variable "sut_instance_type" {
  type    = string
  default = "c7i.2xlarge"
}

variable "support_instance_type" {
  description = "MySQL + Redis. Redis 는 AOF 를 켜므로 디스크도 쓴다."
  type        = string
  default     = "m7i.xlarge"
}

variable "load_instance_type" {
  description = "k6. 부하 생성기가 병목이 되면 측정이 전부 무의미해진다."
  type        = string
  default     = "c7i.2xlarge"
}
