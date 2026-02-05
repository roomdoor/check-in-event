package com.checkin.event.checkin.controller

import com.checkin.event.checkin.dto.request.CheckInRequest
import com.checkin.event.checkin.dto.response.CheckInRedisResponse
import com.checkin.event.checkin.service.CheckInServiceByRedis
import jakarta.validation.Valid
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController

@RestController
@RequestMapping("/api/redis/events/{eventId}/check-ins")
class CheckInRedisController(
    private val checkInServiceByRedis: CheckInServiceByRedis,
) {

    @PostMapping
    fun checkIn(
        @PathVariable eventId: Long,
        @Valid @RequestBody request: CheckInRequest,
    ): CheckInRedisResponse {
        return checkInServiceByRedis.checkIn(eventId, request.participantKey)
    }
}
