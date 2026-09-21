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
        if (!accepted) {
            // 거절은 원장에 남기지 않는다. 선착순은 정원보다 요청이 훨씬 많아서
            // 거절까지 저장하면 쓰기의 대부분이 "떨어진 사람" 기록이 된다.
            // Redis 경로도 같은 이유로 스트림에 넣지 않는다(CheckInRedisStore).
            // 두 방식의 처리량을 비교하려면 양쪽이 같은 일을 해야 한다.
            return CheckInResponse(
                id = null,
                eventId = eventId,
                participantKey = normalizedKey,
                result = CheckInResult.REJECTED,
                createdAt = now,
            )
        }
        event.acceptedCount += 1

        // 여기까지 왔으면 승인이다. 거절은 위에서 저장 없이 반환했다.
        return try {
            checkInRepository.save(
                CheckIn(
                    event = event,
                    participantKey = normalizedKey,
                    accepted = true,
                    createdAt = now,
                ),
            ).toResponse()
        } catch (ex: DataIntegrityViolationException) {
            val stored = checkInRepository.findByEventIdAndParticipantKey(eventId, normalizedKey)
                ?: throw ex
            event.acceptedCount = (event.acceptedCount - 1).coerceAtLeast(0)
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
