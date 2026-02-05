package com.checkin.event.event.dto.response

import java.time.LocalDateTime

data class EventResponse(
    val id: Long,
    val name: String,
    val capacity: Int,
    val acceptedCount: Int,
    val remaining: Int,
    val startsAt: LocalDateTime?,
    val endsAt: LocalDateTime?,
    val status: EventStatus,
)

enum class EventStatus {
    OPEN,
    CLOSED,
}
