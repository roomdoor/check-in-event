package com.checkin.event.checkin.dto.request

import jakarta.validation.constraints.NotBlank

data class CheckInRequest(
    @field:NotBlank
    val participantKey: String,
)
