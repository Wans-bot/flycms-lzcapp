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

## 10. 版本号与镜像搬运

- 上游 `backend/pom.xml` 版本是 `1.0-SNAPSHOT`，仓库**没有 tag 也没有 Release**
  （`GET /repos/sunkaifei/FlyCms/tags` 与 `/releases` 均返回空）。
  因此 `package.yml` 用 `1.0.0-1`：把 SNAPSHOT 当未定版，末位留给打包修订。
- 镜像在 GitHub Actions 里构到 `ghcr.io/wans-bot/flycms-lzcapp{,-web}:<sha前12位>`，
  再用 `lzc-cli appstore copy-image` 搬到 `registry.lazycat.cloud`。
- **坑**：`copy-image` 是服务端匿名拉取，私有 ghcr 包会报
  `UNAUTHORIZED: authentication required`；而 GitHub 的
  `PATCH /user/packages/container/{name}` 对「挂在仓库下的包」一律返回 404，
  API 改不了可见性。只能让包本身匿名可拉。

## 11. 首次安装启动失败：半套表的坑

第一次实机安装后 `-flycms-1`（后端）与 `-web-1` 都是 `Exited (1)`，后端日志报
`java.sql.SQLSyntaxErrorException: Table 'flycms.fly_config_web' doesn't exist`。

根因不在 SQL 本身，而在初始化脚本的幂等判断：

- 旧脚本用「`fly_admin` 表是否存在」判断要不要导入。上一次导入中途失败留下了 6 张表，
  其中就有 `fly_admin`，于是重跑时直接跳过导入、照写 `/tmp/init-db.done`。
- init 容器随即被判健康，后端带着 6 张表的残库启动，查 `fly_config_web` 必然失败。
- 旧脚本还有第二个坑：`mysql ... < "$SQL" | tail -20` 的退出码是 `tail` 的，
  导入失败也会打印「成功」。

现在的策略：**按库表数量判断 + 失败即退出**（`content/init-db.sh`）

- 表数 < `LZC_EXPECTED_TABLES`（默认 80，上游实际 84）→ `DROP DATABASE` 重建后重导；
- 重导后再数一次表，仍不足就 `exit 1` 且不写 done 标记，healthcheck 保持失败，
  容器被重启后整库重来。这样应用任何时刻都不会带着半套表对外服务。
- 实测日志：`当前 flycms 库表数量：6（下限 80）` → 重建导入 → `84（下限 80）` → 常驻。

## 12. schema 版本号：为什么不再逐列打补丁

第一次修完「表存在但列不全」后，入口仍然 500，只是换了个列名：

```
Unknown column 'use_content'  → Unknown column 'relate_model'  → Unknown column 'is_unique'
```

原因是 baseline `sql/flycms.sql` 是上游 2026-09-28 09:33 的导出，比 master 落后 29 个迁移；
逐条判断只能保证「这张表在」，管不了「这一列在」，于是每次都在不同位置补一块，永远补不完。
迁移文件里还有 11 处 `ADD COLUMN ... AFTER <前一个迁移才加的列>`，按文件名顺序执行会撞车
（`model-field-advanced` 排在 `model-field-relate` 前面）。

现在的策略：**整库重建 + 迁移全量重放 + 关键列校验 + 版本号登记**（`content/init-db.sh`）

- 库内 `fly_lzc_schema_state.rev` 与脚本的 `LZC_SCHEMA_REV`（当前 `3`）不一致 → `DROP DATABASE`
  后重导基线、重放 `content/sql/migrations/*.sql`；
- 一致就直接常驻，重启不重放（迁移里有不带保护的 `INSERT`，重放会插重复行）；
- 上游那 11 处 `AFTER <前一个迁移才加的列>` 已在本仓库的迁移副本里去掉（列位置对应用无影响），顺序因此无关；
- 收尾校验 `fly_model.use_content` + `fly_model_field.relate_model/is_unique`，缺一即 `exit 1`。
- **改了基线或迁移就必须递增 `LZC_SCHEMA_REV`**，否则老库不会重建。

## 13. 部署适配（四）：去掉 /questions/ 死链

上游 demo 数据只带 4 个模型（`images` / `downloads` / `articles` / `testdemo`），没有「问答」模型，
也没有对应的 `fly_cmodel_questions` 内容表；但主题把 `/questions/` 写成导航硬链接
（`common/header.html` 一行、`common/footer.html` 三行、首页 `index.html` 三行），于是入口点向 404，
而 `list-questions.html` 里的 `<@fly_list_model model="questions" orderby="weight">` 还会在日志里刷
`Unknown column 'weight'`。

两条路都试过：
- 补数据：手工插一行 `fly_model` 能消掉 404，但随后报 `Unknown column 'weight'`，
  等于要自己造表、造字段、造内容，属于替上游编数据，不做。
- 删链接：在 `Dockerfile` 构建期删掉这些硬链接行。header 与 footer 共 4 行，断言 `-ge 3`；
  首页 `index.html` 另有 3 行（hero 快捷入口 + 「问答社区」区块标题），但同一文件里
  还有一行 `${q.shortUrl}` 的动态链接属于列表项，不能一起删，所以这一路只删「不含 `${` 的行」并单独断言。
  两条都删完再各断一次 grep 为 0。导航里不出现问答，好过让用户点到 404；
  将来上游改了模板结构，行数跌破下界就会构建失败提醒，不会静默漏改。

## 14. 部署适配（五）：后台 SPA 的 base 与 turbo 的 env 剥离

后台白屏排查的完整链条，坑在「HTTP 200 但页面是空的」，回归脚本按状态码判定，测不出来。

症状：
- `GET /admin/` 返回 200，`<title>FlyCms Console</title>`，看起来完全正常。
- 截图只有 14KB，实际是一片空白。
- 页面 HTML 里引用的是 `/js/xxx.js`、`/_app-config-5.8.0-xxx.js`，**没有 `/admin/` 前缀**。

根因链：
1. `Dockerfile.web` 原本用「过程环境变量」注入 `VITE_BASE=/admin/`。
2. 上游的 `build:antd` 实际是 `pnpm run build --filter=@vben/web-antd`，落到根脚本 `build`，
   而根脚本是 **`turbo build`**。
3. turbo 默认 strict 模式会**剥掉未在 `globalEnv` 声明的环境变量**，上游 `turbo.json` 的
   `globalEnv` 只有 `NODE_ENV`，所以 `VITE_BASE` / `VITE_GLOB_API_URL` 根本到不了 vite。
4. `@vben/vite-config` 的 `loadEnv()` 是用 **dotenv 读 `.env` 文件**，`base: getString(VITE_BASE, '/')`
   拿到的仍是 `.env.production` 里的 `/`。
5. base 是 `/`，SPA 就去请求 `/js/*`，而 nginx 的 `/admin/` location 只管 `/admin/**`，
   这些请求落到 `location /` 被反代给后端，后端没有 `/js/*` 静态资源 → 404 → 白屏。

修法：不再依赖 env 透传，直接在构建期改写文件，并加一条构建期断言。

```
RUN cd apps/web-antd \
 && sed -i 's|^VITE_BASE=.*|VITE_BASE=/admin/|' .env.production \
 && sed -i 's|^VITE_GLOB_API_URL=.*|VITE_GLOB_API_URL=/api|' .env.production \
 && pnpm build:antd
RUN grep -q '"/admin/' /src/frontend/apps/web-antd/dist/index.html || (echo "base 不是 /admin/"; exit 1)
```

最后那条断言是这次的关键：白屏在 HTTP 层完全看不出来，只有检查产物里的引用前缀能在构建期断死。

另外 nginx 侧还有两个细节（`web/nginx.conf`）：
- `location = /admin` 必须 301 到 `/admin/`，否则目录无索引会 403。
- `/admin/index.html` 要 `Cache-Control: no-cache`，否则升级后旧壳子还在加载已被删掉的 chunk。

## 15. 实机验收（1.0.0，2026-10-18）

`box-accept` 18 步全绿（S1 前置 → S9 清理），LPK sha256 前缀 `f54d7aff…`，证据目录 `/tmp/flycms-accept8`。

关键结果：
- S5：5 个容器全部 Up，就绪耗时 16s。
- S6：入口链路含 lzcinit 注入，返回体 15845 字节，注入脚本正常出现。
- S7：门户侧回归 28 页、问题页 0；出图 PC 4 张、移动 0 张（与 `support_mobile: false` 一致）。
- S7b：应用探针 6 条断言全过（健康、就绪、门户中文、无 `/questions/` 死链、后台壳子、列表页）。
- 后台白屏已确认消失。判据不是「HTTP 200」，而是 web 容器访问日志里 `/admin/js/*.js` **全部 200、整份日志零 404**，`zh-cn` 语言包正常加载；`/admin/` 截图 194KB（白屏时只有 14KB）。

提审前仍需清理的模板遗留：后台登录页底部的 vben 模板备案号，以及未接通的手机号/扫码/第三方登录入口。

## 16. 部署适配（六）：清掉后台登录页的 vben 模板遗留

上游后台是 vben（web-antd）脚手架，直接构建会带着模板自己的痕迹上线。`tools/patch-login.mjs` 在构建期改三处：

- **语言包**（`packages/locales/src/langs/zh-CN/authentication.json`）：`pageTitle`「开箱即用的大型中后台管理系统」与 `pageDesc`「工程化、高性能、跨组件库的前端模版」是登录页主副标题，留着就是「这是模板」的自证。改成 FlyCms 自己的文案。
  - 注意路径：语言包是**按域分文件**的目录结构（`langs/zh-CN/authentication.json`），不是单文件 `zh-CN.json`。写错路径构建会直接 ENOENT。
- **备案号**（`packages/@core/preferences/src/config.ts` 默认 `icp: '闽ICP备19024351号'`）：那是模板作者的备案号，绝不能在别人机器上显示。应用层 `preferences` 里覆盖成空。
- **未接通的登录入口**：`mobileLogin` / `qrcodeLogin` / `thirdPartyLogin` 三条在 FlyCms 后端都没有对应实现，点了只会报错。置空后按钮不再渲染。

`tools/verify-ui.mjs` 用 CDP 直连后台逐条断言（6/6 通过）：无他人备案号、无 vben 版权字样、无未接通的手机号/扫码/第三方入口、**验证码仍保留**。最后一条是刻意的——验证码是 FlyCms 自己的登录安全机制，属于应用功能，不在清理范围内。

## 17. 部署适配（七）：关掉上游的模板调试条

上游 SQL 导出时系统配置里开着模板调试：`fly_config_web` 里有一行 `('900331','0','template_debug','1',NULL,'0')`。该开关打开时 `TemplateResolver.resolveAndExpose` 会往模板上下文写 `__tpl`，于是 `pc_theme/defalut/common/debug-bar.html` 在**每一页**左下角浮出一个角标：

```
TPL · index.html · default
```

它同时暴露模板文件名、主题名和模板查找链，既像调试版，也把「这是模板套出来的站」写在脸上——提审会被打回。

修法不是改模板（那样每次同步上游都要重打补丁），而是在 `content/init-db.sh` 初始化末尾幂等地把它关掉：

```bash
mysql -h "$HOST" -u"$USER" "$DB" -e \
  "UPDATE fly_config_web SET keyvalue='0' WHERE keycode='template_debug';" >/dev/null 2>&1 \
  || log "关闭模板调试条失败（不致命）"
```

关闭后 `__tpl` 根本不进上下文，`debug-bar.html` 的 `<#if (__tpl)??>` 整段零输出，与「线上完全一致」——这是上游自己注释里写明的行为，所以不需要删文件。

顺带一个技能库修复：`box-browser.mjs shots` 原来所有页面共用同一个标签页，某个重页面把标签页弄崩（`Page.captureScreenshot: Session closed`）会让整批出图归零、验收直接 S7 失败。已改成逐页 try/catch + 重建标签页重试一次，单页失败只记一行 `× 该页未出图`。

## 18. 商店素材：图标升到 512×512

本地 `icon.png` 原为 **256×256**（4934 字节），而商店列表位通常按 512 显示，256 会被放大发虚。已换成 **512×512**（19634 字节）。

做法是「放大」而不是「重画」：这个图标是纯扁平渐变（垂直 `rgb(45,105,252)` → `rgb(32,88,227)` → `rgb(19,72,203)`）+ 居中白色几何 `F`，属于可无损重采样的图形；重画等于换 logo，与「保持上游品牌一致」冲突。

本机没有 PIL / ImageMagick / rsvg / inkscape / cairosvg / sharp，所以借 Chromium 自己的缩放器：`/tmp/make-icon512.mjs` 把原图按 256 CSS 像素摆放、`deviceScaleFactor: 2` 截屏，直接得到 512 物理像素；`omitBackground: true` + 透明 `body` 保住原图的透明圆角（四角 alpha 实测 0.000，没有被补白底）。

复核两点：`icon.png` 头部宽高 = `(512, 512)`；LPK 包内 `icon.png` 同为 512×512（`tar -xf application.lpk` 后核对）。图标变更后 LPK 重新打包，sha256 变为 `5b52cbce13ad5d96aacef59117c9db1734b2eef4f0d1d28f782241f8a0693140`。

截图沿用 `docs/screenshots/` 下 4 张 1920×1080（PC 位 2–8 张的要求已满足，移动位因 `support_mobile: false` 不提交）。

## 19. 演示内容：把上游桩数据补成可展示状态

商店截图第 3 张原本是一张**空文章页**——正文区只有主题的空态提示「本文暂无正文内容。可先浏览 文章模型，或返回 首页 浏览其他内容。」这类图会被当成「打开就是坏的」。

排查后发现不是模板问题，是数据问题。上游 SQL 里 `fly_cmodel_articles` 的演示数据是这样的：

| 缺陷 | 实测 |
| --- | --- |
| 正文是桩 | 16 条正文长度只有 **0~32 字符**，格式为单行 `<p>一句话</p>` |
| 空稿排最前 | 「定时发布验证稿」「定时发布复测稿」正文 **0 字符**，且 id 最大，而列表按 id 倒序，于是顶在最前面 |
| 标题重复 | `I7RzMf`/`QV7zia` 与 `ar0001aa`/`ar0002bb` 标题完全相同，均为 0 阅读的重复副本 |
| 摘要缺失 | `description`、`keywords` 全为 `NULL`，详情页 `<meta name="description">` 因此为空 |
| 错字 | 「雪崩算法」应为「雪花算法」（Snowflake） |

另外确认了两件不必做的事：主题列表页那个蓝色渐变封面块是**纯 CSS 装饰**，`articles/list.html` 与 `cmodel/list.html` 里根本没有 `img`/`thumbnail`，`fly_images` 表 0 行、`/app/uploadfiles` 空目录——所以「给文章配缩略图」对观感没有任何影响，不用做。

处理方式见 `content/seed-demo.sql`：删掉上述 4 条无效数据（2 条空测试稿 + 2 条重复稿），给剩下 12 篇补 316~446 字符的正文、摘要与关键词，并修正错字。幂等靠独立标记表 `fly_seed_marker`（刻意不写 `fly_config_web`——那是应用的站点配置表，塞一行未知 keycode 会让后台「网站设置」页多出一个陌生字段），由 `content/init-db.sh` 在库导入完成后执行一次，用户后来在后台改过的正文不会被容器重启覆盖。

顺带一个坑：应用对**不存在的短链返回 200**（软 404，渲染空态页而不是 404 页）。所以删掉 `YjaqAv` 之后，旧截图对应的 URL 不会报错、只是继续显示空正文——只靠状态码检查发现不了，必须看正文内容。第 3 张截图改用 `ar0001aa`（自定义模型系统上线公告，88 阅读）。
