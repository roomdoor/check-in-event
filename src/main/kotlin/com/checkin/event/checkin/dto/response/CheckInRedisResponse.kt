package com.checkin.event.checkin.dto.response

import io.swagger.v3.oas.annotations.media.Schema

@Schema(description = "Redis 체크인 응답")
data class CheckInRedisResponse(
    @Schema(description = "이벤트 식별자", example = "8")
    val eventId: Long,
    @Schema(description = "참가자 키", example = "user-1-100-1700000000000")
    val participantKey: String,
    @Schema(description = "체크인 결과")
    val result: CheckInResult,
    @Schema(description = "승인/중복 시 부여된 순번", example = "42")
    val position: Long?,
    @Schema(description = "중복 체크인 여부", example = "false")
    val duplicate: Boolean,
    @Schema(description = "DB 저장 완료 여부", example = "false")
    val persisted: Boolean,
)
