package com.checkin.event.checkin.dto.response

import java.time.LocalDateTime

data class CheckInResponse(
    val id: Long,
    val eventId: Long,
    val participantKey: String,
    val result: CheckInResult,
    val createdAt: LocalDateTime,
)

enum class CheckInResult {
    ACCEPTED,
    REJECTED,
}
