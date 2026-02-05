package com.checkin.event.checkin.controller

import com.checkin.event.checkin.dto.request.CheckInRequest
import com.checkin.event.checkin.dto.response.CheckInRedisResponse
import com.checkin.event.checkin.service.CheckInServiceByRedis
import io.swagger.v3.oas.annotations.Operation
import io.swagger.v3.oas.annotations.Parameter
import io.swagger.v3.oas.annotations.tags.Tag
import jakarta.validation.Valid
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController

@RestController
@RequestMapping("/api/redis/events/{eventId}/check-ins")
@Tag(
    name = "Redis 체크인",
    description = "Redis 기반 체크인 처리 및 비동기 저장",
)
class CheckInRedisController(
    private val checkInServiceByRedis: CheckInServiceByRedis,
) {

    @PostMapping
    @Operation(
        summary = "이벤트 체크인 (Redis)",
        description = "Redis에 체크인을 기록하고 비동기 저장 상태를 반환한다.",
    )
    fun checkIn(
        @Parameter(description = "이벤트 식별자", example = "8")
        @PathVariable eventId: Long,
        @Valid @RequestBody request: CheckInRequest,
    ): CheckInRedisResponse {
        return checkInServiceByRedis.checkIn(eventId, request.participantKey)
    }
}
