package com.checkin.event.event.dto.request

import jakarta.validation.constraints.Min
import jakarta.validation.constraints.NotBlank
import java.time.LocalDateTime

data class CreateEventRequest(
    @field:NotBlank
    val name: String,

    @field:Min(1)
    val capacity: Int,

    val startsAt: LocalDateTime? = null,

    val endsAt: LocalDateTime? = null,
)
