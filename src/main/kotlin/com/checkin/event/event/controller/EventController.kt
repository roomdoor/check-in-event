package com.checkin.event.event.controller

import com.checkin.event.event.dto.request.CreateEventRequest
import com.checkin.event.event.dto.response.EventResponse
import com.checkin.event.event.service.EventService
import io.swagger.v3.oas.annotations.Operation
import io.swagger.v3.oas.annotations.Parameter
import io.swagger.v3.oas.annotations.tags.Tag
import jakarta.validation.Valid
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController

@RestController
@RequestMapping("/api/events")
@Tag(
    name = "이벤트",
    description = "이벤트 생성 및 조회",
)
class EventController(
    private val eventService: EventService,
) {

    @PostMapping
    @Operation(
        summary = "이벤트 생성",
        description = "정원과 선택적 시간 범위를 포함해 이벤트를 생성한다.",
    )
    fun createEvent(@Valid @RequestBody request: CreateEventRequest): EventResponse {
        return eventService.createEvent(request)
    }

    @GetMapping("/{eventId}")
    @Operation(
        summary = "이벤트 상세 조회",
        description = "이벤트 정보와 현재 상태를 반환한다.",
    )
    fun getEvent(
        @Parameter(description = "이벤트 식별자", example = "8")
        @PathVariable eventId: Long,
    ): EventResponse {
        return eventService.getEvent(eventId)
    }
}
