package com.checkin.event.checkin.repository

import com.checkin.event.checkin.entity.CheckIn
import org.springframework.data.jpa.repository.Modifying
import org.springframework.data.jpa.repository.JpaRepository
import org.springframework.data.jpa.repository.Query
import org.springframework.data.repository.query.Param
import java.time.LocalDateTime

interface CheckInRepository : JpaRepository<CheckIn, Long> {
    fun findByEventIdAndParticipantKey(eventId: Long, participantKey: String): CheckIn?

    @Modifying
    @Query(
        value = """
            insert ignore into check_ins (event_id, participant_key, accepted, created_at)
            values (:eventId, :participantKey, :accepted, :createdAt)
        """,
        nativeQuery = true,
    )
    fun insertIgnore(
        @Param("eventId") eventId: Long,
        @Param("participantKey") participantKey: String,
        @Param("accepted") accepted: Boolean,
        @Param("createdAt") createdAt: LocalDateTime,
    ): Int
}
