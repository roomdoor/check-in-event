# AGENTS

This repo is a Kotlin + Spring Boot service for event check-in.
Use this as the single source of truth for build/test commands and code style.

## Project Snapshot
- Build tool: Gradle Kotlin DSL (`build.gradle.kts`).
- Language/runtime: Kotlin, Java 17 toolchain.
- Frameworks: Spring Boot (web, data-jpa, data-redis, validation).
- Datastores: MySQL and Redis (local via `docker-compose.yml`).
- Time zone conventions: Asia/Seoul (Clock + Hibernate + Jackson).

## Quick Commands
Use the Gradle wrapper for all tasks.

```bash
./gradlew clean build
```

```bash
./gradlew test
```

```bash
./gradlew bootRun
```

## Run A Single Test
JUnit 5 is enabled via `useJUnitPlatform()`.

```bash
./gradlew test --tests "com.checkin.event.CheckInEventApplicationTests"
```

```bash
./gradlew test --tests "com.checkin.event.CheckInEventApplicationTests.contextLoads"
```

## Local Dependencies
MySQL and Redis are expected on localhost with defaults from `docker-compose.yml`.

```bash
docker compose up -d
```

## Configuration Notes
- Main config: `src/main/resources/application.yml`.
- MySQL URL: `jdbc:mysql://localhost:3306/checkin_event`.
- Redis: `localhost:6379`.
- Hibernate `ddl-auto: update` (do not change casually).

## Repository Layout
- Application entry: `src/main/kotlin/com/checkin/event/CheckInEventApplication.kt`.
- Controllers: `src/main/kotlin/com/checkin/event/**/controller`.
- Services: `src/main/kotlin/com/checkin/event/**/service`.
- Entities + repositories: `src/main/kotlin/com/checkin/event/**/entity|repository`.
- DTOs: `src/main/kotlin/com/checkin/event/**/dto`.
- Tests: `src/test/kotlin`.

## Code Style: Kotlin
Follow existing Kotlin style in this repo.

- Package declaration at top, blank line, then imports.
- Imports are explicit (no wildcard) and grouped by top-level package:
  `com.*`, `org.*`, `java.*` with blank lines between groups.
- Use trailing commas in multi-line argument lists and data class params.
- Keep constructor params vertically aligned with trailing commas.
- Use `val` by default; `var` only when state must mutate (entities).
- Use data classes for DTOs, enums for finite states.
- Prefer early returns to reduce nesting.

## Naming Conventions
- Packages: all lowercase with dots (`com.checkin.event...`).
- Classes/Interfaces: UpperCamelCase.
- Functions/variables: lowerCamelCase.
- Constants: UPPER_SNAKE in `companion object`.
- REST paths: plural resources, nested where needed.

## Controller Patterns
- Annotate request DTOs with `@Valid` and `@RequestBody`.
- Use `@RestController` + `@RequestMapping` on class.
- Keep controllers thin; delegate to services.
- Path variables are `Long` and named `eventId` where applicable.

## Service Patterns
- Business logic lives in services.
- Mutations should be `@Transactional` when modifying DB state.
- `Clock` is injected with Asia/Seoul default; use `now()` helper.
- Normalize inputs early (e.g., `trim()` for participant keys).

## Error Handling
- Use `ResponseStatusException` with `HttpStatus` for API errors.
- Do not swallow exceptions; return meaningful errors or rethrow.
- Use `runCatching` only when failure is non-fatal and you handle fallback.
- Avoid empty catch blocks and `@Suppress` for exceptions.

## Validation
- Use `jakarta.validation` annotations in request DTOs.
- Example: `@field:NotBlank`, `@field:Min(1)`.
- Validate in service for cross-field constraints (e.g., time windows).

## Data Access
- Repositories extend `JpaRepository`.
- Use `@Query` and `@Modifying` for custom updates.
- Prefer explicit locking when concurrency matters (`@Lock`).
- For upserts/insert-ignore, use native queries as shown in `CheckInRepository`.

## Redis Integration
- Redis check-ins are handled by a Lua script in `CheckInRedisStore`.
- The script returns `[code, position]` where code is accepted/duplicate/reject.
- Do not modify Lua script semantics without updating decoder logic.
- Stream processing uses `CheckInStreamWriter` and `CheckInStreamPersistService`.

## Time And Locale
- Time zone is fixed to Asia/Seoul for DB and JSON.
- Use `Clock` and `LocalDateTime.now(clock)` for current time.
- Avoid `LocalDateTime.now()` directly unless consistent with existing usage.

## Testing
- Only one Spring context test exists now: `CheckInEventApplicationTests`.
- Use JUnit 5 and `@SpringBootTest` for integration tests.
- Keep test classes in `src/test/kotlin` with matching packages.

## Linting And Formatting
- No ktlint or detekt configuration found.
- Do not introduce new formatters without team agreement.
- Keep formatting consistent with existing files.

## Tooling Rules
- Use `./gradlew` wrapper, not system Gradle.
- Avoid destructive git commands or force pushes unless asked.
- Prefer minimal, focused changes; no broad refactors for bug fixes.

## Cursor/Copilot Instructions
- No `.cursorrules`, `.cursor/rules/`, or `.github/copilot-instructions.md` found.
- If these files are added later, update this guide.

## When In Doubt
- Follow patterns in existing service/controller/repository code.
- Prefer clarity over cleverness; keep functions small and focused.
- Leave TODOs only when necessary and clearly scoped.
