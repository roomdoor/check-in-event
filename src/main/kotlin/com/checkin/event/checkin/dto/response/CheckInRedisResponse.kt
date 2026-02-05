package com.checkin.event.checkin.dto.response

data class CheckInRedisResponse(
    val eventId: Long,
    val participantKey: String,
    val result: CheckInResult,
    val position: Long?,
    val duplicate: Boolean,
    val persisted: Boolean,
)
