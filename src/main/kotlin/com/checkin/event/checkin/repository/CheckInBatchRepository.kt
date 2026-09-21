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

    /**
     * events.accepted_count 를 실제 저장된 승인 행 수로 맞춘다.
     *
     * 세고 나서 쓰는 두 문장으로 나누면 그 사이에 db 모드 체크인이 끼어들 수 있다.
     * 999 를 읽은 뒤 누군가 1000 으로 올리고 이쪽이 999 를 덮어쓰면, 다음 요청이
     * 정원이 남았다고 보고 1001 번째를 받는다. 한 문장으로 두면 그 틈이 없다.
     *
     * COUNT 는 idx_checkins_event_accepted 를 탄다. 거절도 전부 행으로 남기 때문에
     * 이벤트 하나에 수십만 행이 쌓이고, 덮는 인덱스가 없으면 배치마다 클러스터
     * 인덱스를 훑어 드레인 시간에 그대로 얹힌다.
     */
    fun syncAcceptedCount(eventId: Long) {
        jdbcTemplate.update(
            """
            update events e
               set e.accepted_count =
                   (select count(*) from check_ins c
                     where c.event_id = e.id and c.accepted = 1)
             where e.id = ?
            """.trimIndent(),
            eventId,
        )
    }
}
