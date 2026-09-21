# 실행 이미지만 만든다. jar 는 밖에서 ./gradlew bootJar 로 빌드해 넣는다.
# 빌드를 이미지 안에서 하면 Gradle 캐시가 매번 날아가고, 이미지에 JDK 가 통째로
# 들어간다. CI 가 빌드하고 여기는 그 결과물을 감싸기만 한다.
#
# JRE 17 은 build.gradle.kts 의 java.toolchain 과 같은 버전이다. 더 높은 JRE 로도
# 돌지만, 측정 조건을 하나라도 덜 흔들려고 빌드 대상과 맞춘다.
FROM eclipse-temurin:17-jre

# root 로 실행하지 않는다.
RUN useradd --system --create-home --uid 10001 app

WORKDIR /app

COPY build/libs/check-in-event-*.jar /app/app.jar

USER app

EXPOSE 8080

# DB·Redis 접속 정보는 이미지에 들어있지 않다.
# application.yml 기본값이 localhost 인데, 컨테이너 안에서 localhost 는 컨테이너
# 자신이다. 둘 중 하나로 띄워야 기동 시 커넥션 실패로 죽지 않는다.
#   --network host 로 실행 (앱과 MySQL·Redis 가 같은 호스트에 있는 구성)
#   또는 환경변수로 덮어쓴다 (Spring 완화 바인딩)
#     -e SPRING_DATASOURCE_URL=jdbc:mysql://<host>:3306/checkin_event?rewriteBatchedStatements=true
#     -e SPRING_DATA_REDIS_HOST=<host>
#
# 컨테이너 인자는 그대로 Spring 인자가 된다. 드레이너 설정을 회차마다 바꿀 때 쓴다.
#   docker run <image> --checkin.redis.writer.batch-size=1000 --checkin.redis.writer.delay=100
#
# JVM 플래그는 JAVA_TOOL_OPTIONS 로 넘긴다.
#   docker run -e JAVA_TOOL_OPTIONS="-Xmx2g" ...
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
