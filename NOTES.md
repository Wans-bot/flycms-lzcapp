# FlyCms 可行性验证笔记

> 上游：https://github.com/sunkaifei/FlyCms（AGPL-3.0，3279★，原生 zh-CN）
> 本文件记录验证阶段取证到的事实，供写 manifest / 判断可行性使用。

## 1. 后端构建

- 语言：**Java 24**；框架：**Spring Boot 4.1.1**。
- 产物名固定：`backend/pom.xml` 的 `spring-boot-maven-plugin` + `<finalName>FlyCms.jar</finalName>` → `backend/target/FlyCms.jar`。
- **上游没有 Dockerfile、没有 mvnw、没有 compose**，只能用镜像内 maven 构建。
- 上游 CI（`.github/workflows`）实测命令：JDK 24 temurin + `mvn -B -DskipTests package`。
- 测试依赖 Testcontainers 起真 MySQL，构建期没有 docker-in-docker，必须 `-Dmaven.test.skip=true`。

## 2. 配置（backend/application.yml）

- `server.port: 80`，`server.servlet.context-path: /`。
- 数据源：`jdbc:mysql://localhost:3306/fly-cms?...`，`username: root`，`password: 123456`（占位默认值，需全量覆盖）。
- 模板与静态目录用**相对工作目录**的 `file:` 协议：
  - `file:./views/templates`
  - `file:./uploadfiles`
  → 进程 cwd 必须是 `/app`，否则模板 404。
- 缓存默认 caffeine，可切 redis。
- 环境变量覆盖键（Spring 宽松绑定）：`SPRING_DATASOURCE_URL` / `SPRING_DATASOURCE_USERNAME` / `SPRING_DATASOURCE_PASSWORD`。

## 3. 健康检查与登录（决定 bundle 能否过 S6/S8）

- `GET /api/health`：不依赖 DB/缓存，**恒 200**。
- `GET /api/ready`：检查 DB + 缓存，DB 未就绪会失败。
- `POST /api/auth/login`：**强制图形验证码**，后端校验会话里的 `Const.KAPTCHA_SESSION_KEY`。
  - 验证码接口：`GET /captcha/default` 返回 GIF（4 字符）；另有 `GET /captcha/getJPGCode`。
- 默认管理员：**`flycms` / `admin123`**（SQL 里存的 bcrypt 已核验对应此明文）。

## 4. 数据库

- 上游基础库：`sql/flycms_20260928_093335.sql`，**2554059 字节**，**84 张 CREATE TABLE**，**535 条 INSERT INTO**。
- 导出源是 **MySQL 5.7.44**；文件内**没有 `CREATE DATABASE`、没有 `USE`**，库必须自己建后再导入。
- 引擎混用 MyISAM / InnoDB；字符集混用 utf8 / utf8mb4；**无 DEFINER**（无需 SUPER 权限）。
- MySQL 8 仍兼容 utf8mb3 与 MyISAM，故可直接用官方 mysql 镜像。

## 5. 后台前端（关键风险）

- **`backend/views/` 只有 `pc_theme`（138 个文件）——门户/PC 站模板，没有 admin 模板。**
- 管理后台是独立的 Vben 5 SPA：`frontend/apps/web-antd`（Vue 3 + Vite 7）。
- `frontend/apps/web-antd/.env.production`：
  - `VITE_GLOB_API_URL=https://mock-napi.vben.pro/api` ← **上游遗留的 demo 地址，必须改**（打包后静态写死，运行期改不了）
  - `VITE_ROUTER_HISTORY=hash`、`VITE_BASE=/`
- 前端要求 **Node 22 + pnpm 11**；仓库**未提交构建产物 dist**。

## 6. 懒猫侧可复用件

- MySQL 镜像：`registry.lazycat.cloud/wans/library/mysql:720d8e3ace6b770d`，binds `/lzcapp/var/mysql:/var/lib/mysql`，字符集参数 `--character-set-server=utf8mb4 --collation-server=utf8mb4_0900_ai_ci`。
- 初始化脚本模式（来自 `examples/cloud.lazycat.app.xzs`）：init 容器跑脚本 → 写 `/tmp/*.done` → healthcheck 用 `test -f` → 用完常驻。
- `lzc-manifest.yml` 支持 `configs: {stable_secret}` + `{{ printf "%.24s" (stable_secret "KEY") }}` 生成稳定随机口令。
- 包名 `cloud.lazycat.app.flycms` 经 store API 核查为**空闲**（exist=false）。

## 7. 本阶段路线决定

- 构建走 **GitHub Actions 打镜像 → ghcr.io → 本地 `lzc-cli appstore copy-image` 搬官方源**（13ft 已验证过的链路），
  不用 `lzc-build.yml` 的 `embed:`（未验证路径）。
- 先用**单服务 + mysql 两容器**跑通，admin SPA 单独评估。

## 8. 部署适配（三个必须改的点）

上游按「自己的域名 + 独立部署前端」写的配置，搬到盒子必须处理：

1. **CORS 会把盒子域名判成跨域并 403**
   `backend/src/main/java/com/flycms/config/CorsConfig.java` 用 `@Value("${flycms.cors.allowed-hosts:localhost,127.0.0.1}")`
   拼 `http(s)://host[:*]` 白名单；盒子域名每个用户不同、构建期不可知。
   反代后后端看到 `http` + 盒子域名，浏览器给的 Origin 是 `https` + 盒子域名，
   Spring 的 `CorsUtils.isCorsRequest` 会判定为跨域 → 命中白名单失败。
   **对策**：nginx 单入口处 `proxy_set_header Origin "";`，让后端按同源处理；
   跨站防护交给 CSRF 双提交。

2. **CSRF 是双提交 Cookie 模型，与 axios 默认值刚好对上**
   `backend/src/main/java/com/flycms/filter/CsrfFilter.java`：安全方法下发 `XSRF-TOKEN` Cookie
   （`httpOnly=false`，Path=/，会话级），非安全方法比对 Cookie 与请求头 `X-XSRF-TOKEN`；
   仅对 `config.pathPrefix`（默认 `/api/`）生效。
   axios 默认 `xsrfCookieName='XSRF-TOKEN'` / `xsrfHeaderName='X-XSRF-TOKEN'`，与之一致，
   但前提是 SPA 与后端同源（本方案同源），且**首个不安全请求前必须先发过一个 GET**把 Cookie 种下
   ——登录页本来就先取图形验证码，天然满足。

3. **multipart 默认只有 2MB**
   `spring.servlet.multipart.max-file-size: 2MB`，后台上传封面图必超。用
   `SPRING_SERVLET_MULTIPART_MAX_FILE_SIZE` / `..._MAX_REQUEST_SIZE` 提到 64MB，
   nginx 侧 `client_max_body_size 200m`。

## 9. 后台 SPA 的托管方案

- 上游没有把后台打进后端：`backend/views/` 只有 `pc_theme`，`resources` 里也没有静态后台资源。
- 因此新增 `Dockerfile.web`：node 24 构建 `frontend`（pnpm 11.16.0）→ nginx 托管 `apps/web-antd/dist`。
- 构建期覆盖两个变量：`VITE_GLOB_API_URL=/api`、`VITE_BASE=/admin/`
  （Vite 规则：`process.env` 里已存在的 `VITE_*` 优先级高于 `.env.production`）。
- SPA 是 **hash 路由**（`VITE_ROUTER_HISTORY=hash`），所以挂在 `/admin/` 子路径不需要服务端 rewrite，
  nginx 只需 `try_files $uri $uri/ /admin/index.html`。
- nginx 同时承担 `/` 与 `/api/` 到 `flycms:80` 的反代，成为唯一入口。
