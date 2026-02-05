package com.checkin.event.checkin.dto.response

import io.swagger.v3.oas.annotations.media.Schema
import java.time.LocalDateTime

@Schema(description = "체크인 응답")
data class CheckInResponse(
    @Schema(description = "체크인 식별자", example = "1")
    val id: Long,
    @Schema(description = "이벤트 식별자", example = "8")
    val eventId: Long,
    @Schema(description = "참가자 키", example = "user-1-100-1700000000000")
    val participantKey: String,
    @Schema(description = "체크인 결과")
    val result: CheckInResult,
    @Schema(description = "체크인 시각", example = "2026-02-05T15:30:00")
    val createdAt: LocalDateTime,
)

@Schema(description = "체크인 결과")
enum class CheckInResult {
    ACCEPTED,
    REJECTED,
}
