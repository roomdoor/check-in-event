plugins {
    // 빌드가 JDK 17 을 요구하는데(java.toolchain, gradle-daemon-jvm.properties)
    // 머신에 없으면 Gradle 이 스스로 받아올 곳이 없다. 이 플러그인이 받아온다.
    id("org.gradle.toolchains.foojay-resolver-convention") version "0.8.0"
}

rootProject.name = "check-in-event"
