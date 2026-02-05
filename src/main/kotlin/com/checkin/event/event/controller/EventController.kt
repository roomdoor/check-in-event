package com.checkin.event.event.controller

import com.checkin.event.event.dto.request.CreateEventRequest
import com.checkin.event.event.dto.response.EventResponse
import com.checkin.event.event.service.EventService
import jakarta.validation.Valid
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController

@RestController
@RequestMapping("/api/events")
class EventController(
    private val eventService: EventService,
) {

    @PostMapping
    fun createEvent(@Valid @RequestBody request: CreateEventRequest): EventResponse {
        return eventService.createEvent(request)
    }

    @GetMapping("/{eventId}")
    fun getEvent(@PathVariable eventId: Long): EventResponse {
        return eventService.getEvent(eventId)
    }
}
