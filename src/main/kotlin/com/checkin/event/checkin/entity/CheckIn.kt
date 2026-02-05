package com.checkin.event.checkin.entity

import jakarta.persistence.Column
import jakarta.persistence.Entity
import jakarta.persistence.FetchType
import jakarta.persistence.GeneratedValue
import jakarta.persistence.GenerationType
import jakarta.persistence.Id
import jakarta.persistence.JoinColumn
import jakarta.persistence.ManyToOne
import jakarta.persistence.Table
import jakarta.persistence.UniqueConstraint
import com.checkin.event.event.entity.Event
import java.time.LocalDateTime

@Entity
@Table(
    name = "check_ins",
    uniqueConstraints = [
        UniqueConstraint(
            name = "uk_checkins_event_participant",
            columnNames = ["event_id", "participant_key"],
        ),
    ],
)
class CheckIn(
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    val id: Long = 0,

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "event_id", nullable = false)
    var event: Event,

    @Column(name = "participant_key", nullable = false)
    var participantKey: String,

    @Column(nullable = false)
    var accepted: Boolean,

    @Column(nullable = false)
    var createdAt: LocalDateTime = LocalDateTime.now(),
)
