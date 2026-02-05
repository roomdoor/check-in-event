package com.checkin.event.event.entity

import jakarta.persistence.Column
import jakarta.persistence.Entity
import jakarta.persistence.GeneratedValue
import jakarta.persistence.GenerationType
import jakarta.persistence.Id
import jakarta.persistence.Table
import java.time.LocalDateTime

@Entity
@Table(name = "events")
class Event(
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    val id: Long = 0,

    @Column(nullable = false)
    var name: String,

    @Column(nullable = false)
    var capacity: Int,

    @Column(nullable = false)
    var acceptedCount: Int = 0,

    var startsAt: LocalDateTime? = null,

    var endsAt: LocalDateTime? = null,
) {
    fun isOpen(now: LocalDateTime): Boolean {
        val afterStart = startsAt?.let { !now.isBefore(it) } ?: true
        val beforeEnd = endsAt?.let { !now.isAfter(it) } ?: true
        return afterStart && beforeEnd
    }
}
