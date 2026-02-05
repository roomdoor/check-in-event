package com.checkin.event.checkin.dto.request

import io.swagger.v3.oas.annotations.media.Schema
import jakarta.validation.constraints.NotBlank

@Schema(description = "체크인 요청")
data class CheckInRequest(
    @field:NotBlank
    @Schema(
        description = "참가자 고유 키",
        example = "user-1-100-1700000000000",
    )
    val participantKey: String,
)
