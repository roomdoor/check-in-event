plugins {
    // java.toolchain(17) 이 머신에 없을 때 받아올 곳을 제공한다. 데몬 JVM 은 이
    // 플러그인이 못 받아온다 — 데몬은 이 파일이 평가되기 전에 정해진다. 데몬용
    // 다운로드 URL 은 gradle/gradle-daemon-jvm.properties 에 따로 있고,
    // ./gradlew updateDaemonJvm --jvm-version=17 이 이 플러그인을 써서 그걸 채운다.
    id("org.gradle.toolchains.foojay-resolver-convention") version "0.8.0"
}

rootProject.name = "check-in-event"
