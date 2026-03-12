FROM eclipse-temurin:21-jre-alpine AS builder
WORKDIR /app
COPY target/*.jar app.jar
RUN java -Djarmode=tools -jar app.jar extract --layers --destination extracted

FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
COPY --from=builder /app/extracted/dependencies/ ./
COPY --from=builder /app/extracted/spring-boot-loader/ ./
COPY --from=builder /app/extracted/snapshot-dependencies/ ./
COPY --from=builder /app/extracted/application/ ./
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser
EXPOSE 8443 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
