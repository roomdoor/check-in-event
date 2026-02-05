package com.checkin.event.checkin.service

import com.checkin.event.checkin.dto.response.CheckInRedisResponse
import com.checkin.event.checkin.dto.response.CheckInResult
import com.checkin.event.checkin.redis.CheckInRedisStore
import com.checkin.event.event.repository.EventRepository
import org.springframework.http.HttpStatus
import org.springframework.stereotype.Service
import org.springframework.web.server.ResponseStatusException
import java.time.Clock
import java.time.LocalDateTime
import java.time.ZoneId

@Service
class CheckInServiceByRedis(
    private val eventRepository: EventRepository,
    private val redisStore: CheckInRedisStore,
    private val clock: Clock = Clock.system(ZoneId.of("Asia/Seoul")),
) {
    fun checkIn(eventId: Long, participantKey: String): CheckInRedisResponse {
        val event = eventRepository.findById(eventId)
            .orElseThrow { ResponseStatusException(HttpStatus.NOT_FOUND, "Event not found") }

        val normalizedKey = participantKey.trim()
        val now = now()
        val decision = redisStore.checkIn(
            eventId = eventId,
            participantKey = normalizedKey,
            capacity = event.capacity,
            allowed = event.isOpen(now),
            timestamp = now,
        )

        return CheckInRedisResponse(
            eventId = eventId,
            participantKey = normalizedKey,
            result = if (decision.accepted) CheckInResult.ACCEPTED else CheckInResult.REJECTED,
            position = decision.position,
            duplicate = decision.duplicate,
            persisted = false,
        )
    }

    private fun now(): LocalDateTime = LocalDateTime.now(clock)
}
