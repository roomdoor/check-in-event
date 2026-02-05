package com.checkin.event.event.repository

import com.checkin.event.event.entity.Event
import jakarta.persistence.LockModeType
import org.springframework.data.jpa.repository.JpaRepository
import org.springframework.data.jpa.repository.Lock
import org.springframework.data.jpa.repository.Modifying
import org.springframework.data.jpa.repository.Query
import org.springframework.data.repository.query.Param

interface EventRepository : JpaRepository<Event, Long> {

    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("select e from Event e where e.id = :id")
    fun findByIdForUpdate(@Param("id") id: Long): Event?

    @Modifying
    @Query("update Event e set e.acceptedCount = e.acceptedCount + :delta where e.id = :id")
    fun incrementAcceptedCountBy(
        @Param("id") id: Long,
        @Param("delta") delta: Int,
    ): Int
}
