package com.checkin.event.checkin.controller

import com.checkin.event.checkin.dto.request.CheckInRequest
import com.checkin.event.checkin.dto.response.CheckInResponse
import com.checkin.event.checkin.service.CheckInService
import jakarta.validation.Valid
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController

@RestController
@RequestMapping("/api/events/{eventId}/check-ins")
class CheckInController(
    private val checkInService: CheckInService,
) {

    @PostMapping
    fun checkIn(
        @PathVariable eventId: Long,
        @Valid @RequestBody request: CheckInRequest,
    ): CheckInResponse {
        return checkInService.checkIn(eventId, request.participantKey.trim())
    }
}
