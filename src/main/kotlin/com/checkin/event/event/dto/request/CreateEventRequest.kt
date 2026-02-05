package com.checkin.event.event.dto.request

import io.swagger.v3.oas.annotations.media.Schema
import jakarta.validation.constraints.Min
import jakarta.validation.constraints.NotBlank
import java.time.LocalDateTime

@Schema(description = "이벤트 생성 요청")
data class CreateEventRequest(
    @field:NotBlank
    @Schema(description = "이벤트 이름", example = "Spring Conference")
    val name: String,

    @field:Min(1)
    @Schema(description = "이벤트 정원", example = "100")
    val capacity: Int,

    @Schema(
        description = "이벤트 시작 시각 (선택)",
        example = "2026-02-05T10:00:00",
    )
    val startsAt: LocalDateTime? = null,

    @Schema(
        description = "이벤트 종료 시각 (선택)",
        example = "2026-02-05T18:00:00",
    )
    val endsAt: LocalDateTime? = null,
)
