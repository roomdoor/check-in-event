package com.checkin.event.checkin.service

import com.checkin.event.checkin.redis.CheckInRedisStore
import org.springframework.beans.factory.annotation.Value
import org.springframework.scheduling.annotation.Scheduled
import org.springframework.stereotype.Component

@Component
class CheckInStreamWriter(
    private val redisStore: CheckInRedisStore,
    private val persistService: CheckInStreamPersistService,
    // 한 주기에 가져올 건수. 저장 처리량은 batchSize / (저장시간 + delay) 다.
    // fixedDelay 는 작업이 끝난 뒤부터 세므로, 저장이 느려지면 주기도 같이 길어진다.
    @Value("\${checkin.redis.writer.batch-size:200}")
    private val batchSize: Long,
) {

    @Scheduled(fixedDelayString = "\${checkin.redis.writer.delay:500}")
    fun drainStream() {
        // Redis Stream에 쌓인 체크인 기록을 주기적으로 읽어서 DB에 반영한다.
        val lastId = redisStore.getOffset() ?: "0-0"
        val records = redisStore.readStream(lastId, batchSize)
        if (records.isEmpty()) return

        // persist 실패 시 오프셋을 올리지 않아서 다음 스케줄에 재처리된다.
        // 배치를 키울수록 재시도 단위도 같이 커진다.
        val processed = runCatching { persistService.persist(records) }.getOrElse { false }
        if (processed) {
            redisStore.setOffset(records.last().id.value)
        }
    }
}
