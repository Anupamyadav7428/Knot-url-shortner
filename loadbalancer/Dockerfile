FROM eclipse-temurin:21-jdk AS build

WORKDIR /workspace
COPY gradlew settings.gradle build.gradle ./
COPY gradle ./gradle
COPY src ./src
RUN chmod +x gradlew && ./gradlew --no-daemon bootJar -x test

FROM eclipse-temurin:21-jre

WORKDIR /app
COPY --from=build /workspace/build/libs/*.jar /app/app.jar
ENV PORT=8080
EXPOSE 8080
USER 10001
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar /app/app.jar --server.port=${PORT:-8080}"]