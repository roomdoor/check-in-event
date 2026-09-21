package com.checkin.event.checkin.service

import com.checkin.event.checkin.repository.CheckInBatchRepository
import com.checkin.event.checkin.repository.CheckInInsertRow
import org.springframework.data.redis.connection.stream.MapRecord
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional
import java.time.LocalDateTime
import java.time.ZoneId

@Service
class CheckInStreamPersistService(
    private val checkInBatchRepository: CheckInBatchRepository,
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

        checkInBatchRepository.insertIgnore(rows)

        // 배치 반환값으로 "몇 건 들어갔나"를 셀 수 없다(insertIgnore 주석 참고).
        // 늘리는 대신 실제 저장된 행을 세서 맞춘다. 같은 트랜잭션이라 방금 넣은
        // 행이 보이고, 재처리로 같은 배치가 두 번 와도 결과가 같다. 과거에
        // 어긋나 있던 값도 다음 배치에서 저절로 맞춰진다.
        rows.map { it.eventId }.distinct().forEach { eventId ->
            checkInBatchRepository.syncAcceptedCount(eventId)
        }

        return true
    }
}
