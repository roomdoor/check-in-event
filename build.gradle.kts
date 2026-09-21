plugins {
    id("org.springframework.boot") version "3.3.2"
    id("io.spring.dependency-management") version "1.1.6"
    kotlin("jvm") version "1.9.24"
    kotlin("plugin.spring") version "1.9.24"
    kotlin("plugin.jpa") version "1.9.24"
}

group = "com.checkin"
version = "0.0.1-SNAPSHOT"

java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(17))
    }
}

repositories {
    mavenCentral()
}

dependencies {
    implementation("org.springframework.boot:spring-boot-starter-web")
    implementation("org.springframework.boot:spring-boot-starter-data-jpa")
    implementation("org.springframework.boot:spring-boot-starter-data-redis")
    implementation("org.springframework.boot:spring-boot-starter-validation")
    implementation("com.fasterxml.jackson.module:jackson-module-kotlin")
    implementation("org.jetbrains.kotlin:kotlin-reflect")
    implementation("org.springdoc:springdoc-openapi-starter-webmvc-ui:2.6.0")

    runtimeOnly("com.mysql:mysql-connector-j")

    testImplementation("org.springframework.boot:spring-boot-starter-test")
}

tasks.withType<Test> {
    useJUnitPlatform()
}

// plain jar 는 만들지 않고 실행 jar 의 파일명을 고정한다. Dockerfile 이 정확한
// 경로를 COPY 하게 하려는 것이다. 글로브(check-in-event-*.jar)를 쓰면 BuildKit 은
// 파일이 둘일 때 실패하지 않고 정렬상 마지막 것을 조용히 넣는다 — 버전을 올린 뒤
// clean 없이 bootJar 만 다시 돌리면 옛 jar 가 이미지에 들어가고 에러가 없다.
tasks.jar { enabled = false }
tasks.bootJar { archiveFileName.set("app.jar") }
