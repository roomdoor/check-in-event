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
        val lastId = redisStore.getOffset() ?: "0-0"
        val records = redisStore.readStream(lastId, BATCH_SIZE)
        if (records.isEmpty()) return

        records.forEach { record ->
            val processed = runCatching { persistService.persist(record) }.getOrElse { false }
            if (processed) {
                redisStore.setOffset(record.id.value)
            }
        }
    }

    companion object {
        private const val BATCH_SIZE = 200L
    }
}
