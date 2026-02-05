package com.checkin.event.checkin.redis

import org.springframework.data.redis.connection.stream.MapRecord
import org.springframework.data.redis.connection.stream.ReadOffset
import org.springframework.data.redis.connection.stream.StreamOffset
import org.springframework.data.redis.connection.stream.StreamReadOptions
import org.springframework.data.redis.core.StringRedisTemplate
import org.springframework.data.redis.core.script.DefaultRedisScript
import org.springframework.stereotype.Component
import java.time.LocalDateTime

data class CheckInRedisDecision(
    val accepted: Boolean,
    val duplicate: Boolean,
    val position: Long?,
)

@Component
class CheckInRedisStore(
    private val redisTemplate: StringRedisTemplate,
) {
    fun checkIn(
        eventId: Long,
        participantKey: String,
        capacity: Int,
        allowed: Boolean,
        timestamp: LocalDateTime,
    ): CheckInRedisDecision {
        // 1) Lua 스크립트로 Redis 연산을 원자적으로 처리한다.
        // 2) 스크립트 반환값은 [code, position] 형식이다.
        //    - code: 1=승인, 2=중복, 0=거절
        //    - position: 승인/중복 시 배정된 순번
        val result = redisTemplate.execute(
            CHECKIN_SCRIPT,
            listOf(usersKey(eventId), countKey(eventId), posKey(eventId), STREAM_KEY),
            participantKey,
            capacity.toString(),
            if (allowed) "1" else "0",
            eventId.toString(),
            timestamp.toString(),
        ) ?: throw IllegalStateException("Redis check-in failed")

        val code = toLong(result.getOrNull(0))
        val position = toLong(result.getOrNull(1)).takeIf { it > 0 }
        val duplicate = code == CODE_DUPLICATE
        val accepted = code == CODE_ACCEPTED || duplicate

        return CheckInRedisDecision(
            accepted = accepted,
            duplicate = duplicate,
            position = position,
        )
    }

    fun readStream(lastId: String, count: Long): List<MapRecord<String, String, String>> {
        // 마지막 처리 ID 이후의 스트림 엔트리를 읽는다.
        val stream = redisTemplate.opsForStream<String, String>()
        return stream.read(
            StreamReadOptions.empty().count(count),
            StreamOffset.create(STREAM_KEY, ReadOffset.from(lastId)),
        ) ?: emptyList()
    }

    fun getOffset(): String? = redisTemplate.opsForValue().get(OFFSET_KEY)

    fun setOffset(id: String) {
        redisTemplate.opsForValue().set(OFFSET_KEY, id)
    }

    // Redis 키 구조
    // - event:{id}:users  : 승인된 사용자 집합(중복 방지)
    // - event:{id}:count  : 승인된 인원 수 카운터
    // - event:{id}:pos    : 사용자별 순번 저장(hash)
    // 키 TTL 정책(현재 미적용): 이벤트 종료 시점 기준으로 TTL을 걸어 정리하는 방식 권장
    // 예: event:{id}:* 키에 EXPIRE(종료+버퍼) 적용
    private fun usersKey(eventId: Long) = "event:$eventId:users"
    private fun countKey(eventId: Long) = "event:$eventId:count"
    private fun posKey(eventId: Long) = "event:$eventId:pos"

    private fun toLong(value: Any?): Long {
        return when (value) {
            is Long -> value
            is Int -> value.toLong()
            is String -> value.toLongOrNull() ?: 0L
            else -> 0L
        }
    }

    companion object {
        // Stream 키(비동기 DB 저장 큐)와 오프셋 저장 키
        // Stream 정책(현재 미적용): 필요 시 XTRIM/MAXLEN으로 스트림 길이 제한 가능
        // 예: XTRIM checkins:stream MAXLEN ~ 100000
        private const val STREAM_KEY = "checkins:stream"
        private const val OFFSET_KEY = "checkins:stream:offset"
        private const val CODE_ACCEPTED = 1L
        private const val CODE_DUPLICATE = 2L

        @Suppress("UNCHECKED_CAST")
        private val CHECKIN_SCRIPT = DefaultRedisScript<List<Any>>(
            """
            -- KEYS[1] users set, KEYS[2] count, KEYS[3] position hash, KEYS[4] stream
            local usersKey = KEYS[1]
            local countKey = KEYS[2]
            local posKey = KEYS[3]
            local streamKey = KEYS[4]

            -- ARGV[1] userId, ARGV[2] capacity, ARGV[3] allowed flag, ARGV[4] eventId, ARGV[5] timestamp
            local userId = ARGV[1]
            local cap = tonumber(ARGV[2])
            local allowed = ARGV[3]
            local eventId = ARGV[4]
            local ts = ARGV[5]

            -- 1) 이미 체크인한 유저면 중복 처리(기존 순번 반환)
            if redis.call('SISMEMBER', usersKey, userId) == 1 then
                local pos = redis.call('HGET', posKey, userId)
                return {2, tonumber(pos)}
            end

            -- 2) 이벤트가 닫혀 있으면 거절 기록 후 종료
            if allowed ~= '1' then
                redis.call('XADD', streamKey, '*', 'eventId', eventId, 'userId', userId, 'accepted', '0', 'position', '0', 'ts', ts)
                return {0, 0}
            end

            -- 3) 정원이 찼으면 거절 기록 후 종료
            local count = tonumber(redis.call('GET', countKey) or '0')
            if count >= cap then
                redis.call('XADD', streamKey, '*', 'eventId', eventId, 'userId', userId, 'accepted', '0', 'position', '0', 'ts', ts)
                return {0, 0}
            end

            -- 4) 승인: 카운터 증가 -> 사용자 등록 -> 순번 저장 -> 스트림에 기록
            local pos = redis.call('INCR', countKey)
            redis.call('SADD', usersKey, userId)
            redis.call('HSET', posKey, userId, pos)
            redis.call('XADD', streamKey, '*', 'eventId', eventId, 'userId', userId, 'accepted', '1', 'position', tostring(pos), 'ts', ts)
            return {1, pos}
            """.trimIndent(),
            List::class.java as Class<List<Any>>,
        )
    }
}
