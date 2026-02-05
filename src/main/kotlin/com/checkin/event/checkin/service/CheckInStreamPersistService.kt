package com.checkin.event.checkin.service

import com.checkin.event.checkin.repository.CheckInBatchRepository
import com.checkin.event.checkin.repository.CheckInInsertRow
import com.checkin.event.event.repository.EventRepository
import org.springframework.data.redis.connection.stream.MapRecord
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional
import java.time.LocalDateTime
import java.time.ZoneId

@Service
class CheckInStreamPersistService(
    private val checkInBatchRepository: CheckInBatchRepository,
    private val eventRepository: EventRepository,
) {
    @Transactional
    fun persist(records: List<MapRecord<String, String, String>>): Boolean {
        if (records.isEmpty()) return true

        // Redis Stream 레코드를 DB 체크인 테이블에 배치로 반영한다.
        val now = LocalDateTime.now(ZoneId.of("Asia/Seoul"))
        val rows = records.mapNotNull { record ->
            val values = record.value
            val eventId = values["eventId"]?.toLongOrNull() ?: return@mapNotNull null
            val participantKey = values["userId"]?.trim().orEmpty()
            if (participantKey.isEmpty()) return@mapNotNull null

            val accepted = values["accepted"] == "1"
            val createdAt = values["ts"]?.let { ts ->
                runCatching { LocalDateTime.parse(ts) }.getOrNull()
            } ?: now

            CheckInInsertRow(
                eventId = eventId,
                participantKey = participantKey,
                accepted = accepted,
                createdAt = createdAt,
            )
        }

        if (rows.isEmpty()) return true

        val inserted = checkInBatchRepository.insertIgnore(rows)
        val acceptedIncrements = mutableMapOf<Long, Int>()
        rows.forEachIndexed { index, row ->
            if (inserted.getOrNull(index)?.let { it > 0 } == true && row.accepted) {
                acceptedIncrements[row.eventId] = (acceptedIncrements[row.eventId] ?: 0) + 1
            }
        }
        acceptedIncrements.forEach { (eventId, count) ->
            eventRepository.incrementAcceptedCountBy(eventId, count)
        }

        return true
    }
}
