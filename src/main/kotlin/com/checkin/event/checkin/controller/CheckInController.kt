package com.checkin.event.checkin.controller

import com.checkin.event.checkin.dto.request.CheckInRequest
import com.checkin.event.checkin.dto.response.CheckInResponse
import com.checkin.event.checkin.service.CheckInService
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
@RequestMapping("/api/events/{eventId}/check-ins")
@Tag(
    name = "체크인",
    description = "DB 락 기반 체크인 처리",
)
class CheckInController(
    private val checkInService: CheckInService,
) {

    @PostMapping
    @Operation(
        summary = "이벤트 체크인",
        description = "DB 락 기반으로 체크인을 생성하고 결과를 반환한다.",
    )
    fun checkIn(
        @Parameter(description = "이벤트 식별자", example = "8")
        @PathVariable eventId: Long,
        @Valid @RequestBody request: CheckInRequest,
    ): CheckInResponse {
        return checkInService.checkIn(eventId, request.participantKey.trim())
    }
}
