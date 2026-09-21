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
    /**
     * 반환값을 일부러 주지 않는다. 데이터소스가 rewriteBatchedStatements=true 라
     * 드라이버가 배치를 다중행 INSERT 한 문장으로 합치고, 그러면 행별 갱신 건수를
     * 알 수 없어 JDBC 규약대로 SUCCESS_NO_INFO(-2) 가 돌아온다. 이걸 "삽입된 행"
     * 으로 세면 항상 0이 된다 — 실제로 그 버그가 있었다(이슈 #1).
     * 몇 건이 들어갔는지는 [countAccepted] 로 다시 센다.
     */
    fun insertIgnore(rows: List<CheckInInsertRow>) {
        if (rows.isEmpty()) return

        val sql = """
            insert ignore into check_ins (event_id, participant_key, accepted, created_at)
            values (?, ?, ?, ?)
        """.trimIndent()

        jdbcTemplate.batchUpdate(
            sql,
            rows,
            rows.size,
        ) { ps, row ->
            ps.setLong(1, row.eventId)
            ps.setString(2, row.participantKey)
            ps.setBoolean(3, row.accepted)
            ps.setTimestamp(4, Timestamp.valueOf(row.createdAt))
        }
    }

    /** 이벤트에 실제로 저장된 승인 행 수. (event_id, participant_key) 유니크 인덱스를 탄다. */
    fun countAccepted(eventId: Long): Int {
        return jdbcTemplate.queryForObject(
            "select count(*) from check_ins where event_id = ? and accepted = 1",
            Int::class.java,
            eventId,
        ) ?: 0
    }
}
