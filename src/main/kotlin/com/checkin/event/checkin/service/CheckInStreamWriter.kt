package com.checkin.event.checkin.service

import com.checkin.event.checkin.redis.CheckInRedisStore
import org.springframework.scheduling.annotation.Scheduled
import org.springframework.stereotype.Component

@Component
class CheckInStreamWriter(
    private val redisStore: CheckInRedisStore,
    private val persistService: CheckInStreamPersistService,
) {

    @Scheduled(fixedDelayString = "\${checkin.redis.writer.delay:500}")
    fun drainStream() {
        // Redis Stream에 쌓인 체크인 기록을 주기적으로 읽어서 DB에 반영한다.
        val lastId = redisStore.getOffset() ?: "0-0"
        val records = redisStore.readStream(lastId, BATCH_SIZE)
        if (records.isEmpty()) return

        // persist 실패 시 오프셋을 올리지 않아서 다음 스케줄에 재처리된다.
        val processed = runCatching { persistService.persist(records) }.getOrElse { false }
        if (processed) {
            redisStore.setOffset(records.last().id.value)
        }
    }

    companion object {
        private const val BATCH_SIZE = 200L
    }
}
