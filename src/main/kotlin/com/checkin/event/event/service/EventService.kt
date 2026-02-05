package com.checkin.event.event.service

import com.checkin.event.event.dto.request.CreateEventRequest
import com.checkin.event.event.dto.response.EventResponse
import com.checkin.event.event.dto.response.EventStatus
import com.checkin.event.event.entity.Event
import com.checkin.event.event.repository.EventRepository
import org.springframework.http.HttpStatus
import org.springframework.stereotype.Service
import org.springframework.web.server.ResponseStatusException
import java.time.Clock
import java.time.LocalDateTime
import java.time.ZoneId

@Service
class EventService(
    private val eventRepository: EventRepository,
    private val clock: Clock = Clock.system(ZoneId.of("Asia/Seoul")),
) {

    fun createEvent(request: CreateEventRequest): EventResponse {
        validateEventWindow(request)
        val event = Event(
            name = request.name.trim(),
            capacity = request.capacity,
            startsAt = request.startsAt,
            endsAt = request.endsAt,
        )
        return eventRepository.save(event).toResponse(now())
    }

    fun getEvent(eventId: Long): EventResponse {
        val event = eventRepository.findById(eventId)
            .orElseThrow { ResponseStatusException(HttpStatus.NOT_FOUND, "Event not found") }
        return event.toResponse(now())
    }

    private fun validateEventWindow(request: CreateEventRequest) {
        val startsAt = request.startsAt
        val endsAt = request.endsAt
        if (startsAt != null && endsAt != null && startsAt.isAfter(endsAt)) {
            throw ResponseStatusException(HttpStatus.BAD_REQUEST, "startsAt must be before endsAt")
        }
    }

    private fun now(): LocalDateTime = LocalDateTime.now(clock)

    private fun Event.toResponse(now: LocalDateTime): EventResponse {
        val remaining = (capacity - acceptedCount).coerceAtLeast(0)
        val status = if (isOpen(now) && remaining > 0) EventStatus.OPEN else EventStatus.CLOSED
        return EventResponse(
            id = id,
            name = name,
            capacity = capacity,
            acceptedCount = acceptedCount,
            remaining = remaining,
            startsAt = startsAt,
            endsAt = endsAt,
            status = status,
        )
    }

}
