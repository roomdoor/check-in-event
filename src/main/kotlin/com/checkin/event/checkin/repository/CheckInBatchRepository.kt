package com.checkin.event.checkin.repository

import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.stereotype.Repository
import java.sql.Timestamp
import java.time.LocalDateTime

data class CheckInInsertRow(
    val eventId: Long,
    val participantKey: String,
    val accepted: Boolean,
    val createdAt: LocalDateTime,
)

@Repository
class CheckInBatchRepository(
    private val jdbcTemplate: JdbcTemplate,
) {
    fun insertIgnore(rows: List<CheckInInsertRow>): IntArray {
        if (rows.isEmpty()) return IntArray(0)

        val sql = """
            insert ignore into check_ins (event_id, participant_key, accepted, created_at)
            values (?, ?, ?, ?)
        """.trimIndent()

        val results = jdbcTemplate.batchUpdate(
            sql,
            rows,
            rows.size,
        ) { ps, row ->
            ps.setLong(1, row.eventId)
            ps.setString(2, row.participantKey)
            ps.setBoolean(3, row.accepted)
            ps.setTimestamp(4, Timestamp.valueOf(row.createdAt))
        }

        return results.flatMap { it.toList() }.toIntArray()
    }
}
