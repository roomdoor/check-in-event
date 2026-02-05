package com.checkin.event.checkin.service

import com.checkin.event.checkin.dto.response.CheckInResponse
import com.checkin.event.checkin.dto.response.CheckInResult
import com.checkin.event.checkin.entity.CheckIn
import com.checkin.event.checkin.repository.CheckInRepository
import com.checkin.event.event.repository.EventRepository
import org.springframework.dao.DataIntegrityViolationException
import org.springframework.http.HttpStatus
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional
import org.springframework.web.server.ResponseStatusException
import java.time.Clock
import java.time.LocalDateTime
import java.time.ZoneId

@Service
class CheckInService(
    private val eventRepository: EventRepository,
    private val checkInRepository: CheckInRepository,
    private val clock: Clock = Clock.system(ZoneId.of("Asia/Seoul")),
) {

    @Transactional
    fun checkIn(eventId: Long, participantKey: String): CheckInResponse {
        val normalizedKey = participantKey.trim()
        val event = eventRepository.findByIdForUpdate(eventId)
            ?: throw ResponseStatusException(HttpStatus.NOT_FOUND, "Event not found")

        val existing = checkInRepository.findByEventIdAndParticipantKey(eventId, normalizedKey)
        if (existing != null) {
            return existing.toResponse()
        }

        val now = now()
        val accepted = event.isOpen(now) && event.acceptedCount < event.capacity
        if (accepted) {
            event.acceptedCount += 1
        }

        return try {
            checkInRepository.save(
                CheckIn(
                    event = event,
                    participantKey = normalizedKey,
                    accepted = accepted,
                    createdAt = now,
                ),
            ).toResponse()
        } catch (ex: DataIntegrityViolationException) {
            val stored = checkInRepository.findByEventIdAndParticipantKey(eventId, normalizedKey)
                ?: throw ex
            if (accepted) {
                event.acceptedCount = (event.acceptedCount - 1).coerceAtLeast(0)
            }
            stored.toResponse()
        }
    }

    private fun now(): LocalDateTime = LocalDateTime.now(clock)

    private fun CheckIn.toResponse(): CheckInResponse {
        val result = if (accepted) CheckInResult.ACCEPTED else CheckInResult.REJECTED
        return CheckInResponse(
            id = id,
            eventId = event.id,
            participantKey = participantKey,
            result = result,
            createdAt = createdAt,
        )
    }
}
