# syntax=docker/dockerfile:1
# FlyCms 后端镜像（多阶段：Maven 构建 → JRE 24 运行）
#
# 上游没有 Dockerfile，也没有 mvnw，只能用镜像内的 maven 构建。
# 源码不进本仓库：构建时按 FLYCMS_REF 拉取，便于用 commit SHA 锁版本。
FROM maven:3.9-eclipse-temurin-24 AS build

ARG FLYCMS_REF=master
WORKDIR /src

# 先只取提交历史做 checkout，再按需取该提交的 blob，避免整仓 99MB 全量拉取
RUN git clone --filter=blob:none --no-checkout https://github.com/sunkaifei/FlyCms.git /src \
 && cd /src \
 && git fetch --depth 1 origin "${FLYCMS_REF}" \
 && git checkout --detach FETCH_HEAD \
 && echo "built from $(git rev-parse HEAD)"

WORKDIR /src/backend
# maven.test.skip 连测试编译一起跳过：上游测试依赖 Testcontainers 起 MySQL，
# 构建期没有 docker-in-docker，编它只会白等还可能失败。
RUN --mount=type=cache,target=/root/.m2 mvn -B -q -Dmaven.test.skip=true package \
 && ls -la target/FlyCms.jar

FROM eclipse-temurin:24-jre

# 运行期需要 curl 做健康检查探针（temurin 基础镜像不带）
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl tzdata fontconfig \
 && rm -rf /var/lib/apt/lists/*

ENV TZ=Asia/Shanghai \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    JAVA_TOOL_OPTIONS="-Duser.timezone=Asia/Shanghai -Dfile.encoding=UTF-8"

WORKDIR /app

COPY --from=build /src/backend/target/FlyCms.jar /app/FlyCms.jar
# application.yml 用 file:./views/templates 与 file:./uploadfiles 做模板与静态目录，
# 相对的是进程工作目录，所以必须落到 /app 下
COPY --from=build /src/backend/views/ /app/views/
COPY --from=build /src/backend/uploadfiles/ /app/uploadfiles/

RUN mkdir -p /app/logs
VOLUME ["/app/uploadfiles", "/app/logs"]

EXPOSE 80

ENTRYPOINT ["java", "-jar", "/app/FlyCms.jar"]
