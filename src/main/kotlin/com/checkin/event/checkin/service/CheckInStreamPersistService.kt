package com.checkin.event.checkin.service

import com.checkin.event.checkin.repository.CheckInRepository
import com.checkin.event.event.repository.EventRepository
import org.springframework.data.redis.connection.stream.MapRecord
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional
import java.time.LocalDateTime
import java.time.ZoneId

@Service
class CheckInStreamPersistService(
    private val checkInRepository: CheckInRepository,
    private val eventRepository: EventRepository,
) {
    @Transactional
    fun persist(record: MapRecord<String, String, String>): Boolean {
        val values = record.value
        val eventId = values["eventId"]?.toLongOrNull() ?: return true
        val participantKey = values["userId"]?.trim().orEmpty()
        if (participantKey.isEmpty()) return true

        val accepted = values["accepted"] == "1"
        val createdAt = values["ts"]?.let { ts ->
            runCatching { LocalDateTime.parse(ts) }.getOrNull()
        } ?: LocalDateTime.now(ZoneId.of("Asia/Seoul"))

        val inserted = checkInRepository.insertIgnore(
            eventId = eventId,
            participantKey = participantKey,
            accepted = accepted,
            createdAt = createdAt,
        )
        if (inserted > 0 && accepted) {
            eventRepository.incrementAcceptedCount(eventId)
        }
        return true
    }
}
