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
        private const val STREAM_KEY = "checkins:stream"
        private const val OFFSET_KEY = "checkins:stream:offset"
        private const val CODE_ACCEPTED = 1L
        private const val CODE_DUPLICATE = 2L

        private val CHECKIN_SCRIPT = DefaultRedisScript<List<Any>>(
            """
            local usersKey = KEYS[1]
            local countKey = KEYS[2]
            local posKey = KEYS[3]
            local streamKey = KEYS[4]

            local userId = ARGV[1]
            local cap = tonumber(ARGV[2])
            local allowed = ARGV[3]
            local eventId = ARGV[4]
            local ts = ARGV[5]

            if redis.call('SISMEMBER', usersKey, userId) == 1 then
                local pos = redis.call('HGET', posKey, userId)
                return {2, tonumber(pos)}
            end

            if allowed ~= '1' then
                redis.call('XADD', streamKey, '*', 'eventId', eventId, 'userId', userId, 'accepted', '0', 'position', '0', 'ts', ts)
                return {0, 0}
            end

            local count = tonumber(redis.call('GET', countKey) or '0')
            if count >= cap then
                redis.call('XADD', streamKey, '*', 'eventId', eventId, 'userId', userId, 'accepted', '0', 'position', '0', 'ts', ts)
                return {0, 0}
            end

            local pos = redis.call('INCR', countKey)
            redis.call('SADD', usersKey, userId)
            redis.call('HSET', posKey, userId, pos)
            redis.call('XADD', streamKey, '*', 'eventId', eventId, 'userId', userId, 'accepted', '1', 'position', tostring(pos), 'ts', ts)
            return {1, pos}
            """.trimIndent(),
        )
    }
}
