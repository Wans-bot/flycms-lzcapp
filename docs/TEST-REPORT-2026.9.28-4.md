# TEST-REPORT — flycms 2026.9.28-4

- 验收时间：2026-10-23 02:03–02:06（CST）
- 目标盒子：`lzcbox`（lzcos v1.6.2 / docker 27.5.1），应用域名 `flycms.wans.heiyu.space`
- LPK：`cloud.lazycat.app.flycms-v2026.9.28-4.lpk`，214,039,552 字节，sha256 `2e64874d4555111b335f5257605cee65b1df8c33e94c5efef91764a24681757f`
- 验收工具：`wans-agent-kb/scripts/box-accept.mjs --skip-install --keep`（G3 实机 + G4 浏览器回归）
- 结论：**verdict = passed**（EVIDENCE.md 全表通过，27 页回归 0 问题）

## 一、本轮修掉的 6 个真缺陷

| # | 缺陷 | 根因 | 修法 | 证据 |
|---|---|---|---|---|
| 1 | 建库即失败 | 上游 `flycms.sql` 把 83 处 `'true'` / 277 处 `'false'` 写进 tinyint 列，MySQL 5.7 静默截断、8.0 报错 | 预处理补丁，两轮共替换 360 处 | migrate 输出 `[flycms] SQL 本地化完成（两轮共 360 处）` |
| 2 | 缺 27 张表 | 镜像内 `flycms-*.jar` 的 `db/migration/*.sql` 未被导入 | init 把 jar 内迁移解出来按序执行，补建 `fly_lzc_schema_state` 记账 | 由 `Unknown table 'fly_cms.fly_model'` → 全部建齐（91 张表） |
| 3 | MinIO 起不来 | `service/data` 目录不存在（compose 的 `volumes` 不会自动建） | post-init 里 `mkdir -p` | 日志 `mkdir -p /data/.minio.sys … 建立成功` |
| 4 | 上传 500 | `storage.conf` 未生成，后台 `FileController` 抛 `NoSuchFileException` | init 按环境变量生成 `storage.conf` 并 `chown` | 日志 `store.s3.endpoint=http://minio:9000 … minio 通道 [OK]` |
| 5 | 首页 500（核心） | CI 的 `lzc-cli project release` 丢弃深层目录（`content/sql/migrations/*.log`），v26 构建同样表现 | 迁移与补丁脚本改为平铺在 `content/` 根下，init 同时扫描两个目录 | 安装后首页 HTTP 200，15,082 字节 FlyCms 门户 HTML |
| 6 | `/admin` 登录页 500 | 后端实体有 `min_value`/`max_value`/`use_*` 等新列，上游 SQL 没建 | 新增 `002-fly_model-columns.sql` 幂等补列（`fly_model` 4 列、`fly_model_field` 6 列） | 22 列 / 32 列核对通过，`/admin/login` 200 |

## 二、验收门槛明细

| 项 | 结果 |
|---|---|
| 容器就绪 | 5 个容器（web / flycms / flycms-init / flycms-db / app）全部 `Up (healthy)` |
| 初始化耗时 | 从 `lpk-manager start` 到 `[seed] 初始化完成` 共 **36 秒** |
| 全页回归 | 27 页，问题页 **0**（`/`、`/admin/login`、`/news/`、`/downloads/`、`/images/` 等） |
| 应用探针（G4） | 退出码 **0**：首页 200 + 正文可读、`/admin/login` 200 + 输入框齐全、页面无 `SQLSTATE`/`Unknown column`/`Internal Server Error` 字样 |
| 截图 | PC **27 张**（1920×1080，无移动截图 —— 已声明不支持移动端） |
| 中文界面 | 18,546 个汉字（阈值 1,000） |
| 容器日志留证 | 6 份 |

## 三、人工看图核对

- 首页：顶栏「Fly Cms / 首页 / 新闻中心 / 下载 / 图集」、正文、热门排名 TOP8、页脚完整渲染，无报错文案。
- 文章封面是深蓝渐变 + 「文章」水印的**占位图**：演示数据没有真实封面图，属设计如此，不是破图。
- `/admin/login`：表单完整，用户名已回填 `flycms`、密码圆点已填、图形验证码留空待手输；页面上有帮助文案与 `测试账户: flycms / admin123` 提示。
- `/images/`：空态提示「暂无内容 / 返回首页」，无报错。

## 四、已知放行（不是修掉了，是可接受）

1. `/testdemo/yEZBja.html` —— 上游自带的早期测试页：整页放行（`--allow-page`）。
2. `/forget_password`、`/admin/login` —— 回归里出现「导航后文档对象被替换」竞态：页面本身截图正常（后台登录页正常渲染），属**回归脚本页面对象失效**，不是页面缺陷。
3. `/sitemap.xml` —— XML 文档，脚本按 HTML 检查 `body` 误报为空白页；curl 校验 `Content-Length: 440`，正常。
4. 外网依赖：`hm.baidu.com`（百度统计）、`unpkg.com`（后台主题 logo）；离线环境会读失败，但页面不阻塞。

## 五、源码级复核清单

按下单时定的「每条驳回逐条核销 + 源码定位」逐项过：

- [x] 首页/后台 500 → `001` 迁移 + `002` 补列 + `content` 平铺（本报告第一节 #5、#6）
- [x] 上传 500 → `storage.conf` 生成（#4）
- [x] MinIO 启动失败 → `service/data` 目录（#3）
- [x] 建库失败 → SQL `true/false` 补丁（#1）
- [x] 缺表 → jar 内迁移回放（#2）
- [x] 默认账号文案 → 商店 description 已改为 `flycms / admin123`（上游 README「安装成功 / 演示站入口」一节明确写的就是这组账号）
- [x] 上游地址 → source 改为 `https://github.com/sunkaifei/FlyCms`
- [x] 不支持移动端 → `--unsupported ios android`、0 张移动截图、description 声明

## 六、提审

- review `#21385`，status=0（待审），提交 2026-10-23T02:15:21Z
- 上传 LPK sha256 `2e64874d4555111b…`（与本地一致）、6 张 PC 截图、中英文 changelog
