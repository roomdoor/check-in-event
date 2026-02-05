package com.checkin.event.event.dto.response

import io.swagger.v3.oas.annotations.media.Schema
import java.time.LocalDateTime

@Schema(description = "이벤트 응답")
data class EventResponse(
    @Schema(description = "이벤트 식별자", example = "8")
    val id: Long,
    @Schema(description = "이벤트 이름", example = "Spring Conference")
    val name: String,
    @Schema(description = "이벤트 정원", example = "100")
    val capacity: Int,
    @Schema(description = "승인된 인원 수", example = "30")
    val acceptedCount: Int,
    @Schema(description = "남은 정원", example = "70")
    val remaining: Int,
    @Schema(description = "이벤트 시작 시각", example = "2026-02-05T10:00:00")
    val startsAt: LocalDateTime?,
    @Schema(description = "이벤트 종료 시각", example = "2026-02-05T18:00:00")
    val endsAt: LocalDateTime?,
    @Schema(description = "현재 이벤트 상태")
    val status: EventStatus,
)

@Schema(description = "이벤트 상태")
enum class EventStatus {
    OPEN,
    CLOSED,
}
