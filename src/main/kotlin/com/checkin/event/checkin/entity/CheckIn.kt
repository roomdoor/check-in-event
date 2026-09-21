package com.checkin.event.checkin.entity

import jakarta.persistence.Column
import jakarta.persistence.Entity
import jakarta.persistence.FetchType
import jakarta.persistence.GeneratedValue
import jakarta.persistence.GenerationType
import jakarta.persistence.Id
import jakarta.persistence.Index
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
    // 승인 인원 집계(CheckInBatchRepository.syncAcceptedCount)가 덮는 인덱스로
    // 끝나게 한다. 유니크 인덱스는 accepted 를 안 담고 있어서, 그것만으로는
    // 이벤트의 모든 행을 클러스터 인덱스에서 다시 읽어야 한다. 그 집계가
    // 배치마다 돌기 때문에 정원이 큰 이벤트에서 드레인 시간에 직접 얹힌다.
    indexes = [
        Index(name = "idx_checkins_event_accepted", columnList = "event_id, accepted"),
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
