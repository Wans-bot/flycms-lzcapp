# FlyCms 商店提审材料

生成时间：2026-10-18　　最终产物：`/tmp/flycms-build/application.lpk`（sha256 `0f5b55f4203b3a73b4f33f0c96d9b00738fff41d061eaebb95ae0f4be9f10a86`，2.9M）

---

## 一、开发者中心「创建应用」要填的字段

| 字段 | 填什么 |
| --- | --- |
| 包名 | `cloud.lazycat.app.flycms` |
| 应用名称 | `FlyCms` |
| 作者 | `sunkaifei` |
| 许可 | **MIT**（已核实：GitHub API `license.spdx_id=MIT`；先前误写 AGPL-3.0 已更正） |
| 主页 | `https://github.com/sunkaifei/FlyCms` |
| 支持 PC | 是 |
| 支持移动端 | **否**（`support_mobile: false` + `unsupported_platforms: [ios, android]`；本包只含 PC 门户主题，未含上游需要额外渲染服务的 H5 主题，移动截图因此为 0） |
| 分类 | 建站 / 网站建设类（若下拉里没有，选最接近的「工具 - 效率」类） |

**简介（brief）**

```
开箱即用的中文企业建站系统：门户、文章、相册、留言与 SEO 一站式管理，装完自带演示内容
```

**关键词**

```
建站,网站,内容管理,CMS,文章,企业官网
```

**详细介绍**

```
FlyCms 是一套开箱即用的企业建站系统。门户首页、文章与自定义内容模型（文章 / 相册 / 视频 / 单页）、留言板、友情链接与 SEO 配置，全部在同一个后台里管理，不需要拼装多个组件。

本次上架的是完整可用的中文版本：

· 门户与后台全中文界面，安装后自带 12 篇演示文章与配套演示数据，装完即可浏览，不需要先配内容
· 后台登录页会自动填入内置管理员账号与密码，只需手动输入图形验证码即可进入 /admin
· 数据库、上传文件、运行日志全部存放在设备本地存储，重启与升级都不丢数据
· 首次启动自动建库、导入基础数据并补齐演示内容，通常一分钟内完成

已知限制：

· 面向 x86_64 设备，界面按桌面浏览器布局，未适配移动端
· 界面语言固定为中文，暂不支持多语言切换
· 邮件发送、短信验证等能力需要在后台自行配置第三方服务
· 默认管理员口令是内置演示口令，正式使用请在后台「系统设置 - 管理员」中修改
· 卸载应用不会删除数据库与上传文件，重新安装会继续使用原有内容
```

---

## 二、素材

| 项 | 路径 |
| --- | --- |
| 图标 | `/home/wans/flycms-lzcapp/icon.png`（512×512，19.6 KB，远低于 200 KB 上限） |
| 截图 1（门户首页） | `/home/wans/flycms-lzcapp/docs/screenshots/01-portal-home.png` |
| 截图 2（文章列表） | `/home/wans/flycms-lzcapp/docs/screenshots/02-portal-news.png` |
| 截图 3（文章详情） | `/home/wans/flycms-lzcapp/docs/screenshots/03-article.png` |
| 截图 4（后台登录页） | `/home/wans/flycms-lzcapp/docs/screenshots/04-admin-login.png` |

4 张均为 1920×1080 实机截图，内容为中文界面真实页面，无模板调试角标、无 Lorem 占位。PC 位要求 2–8 张，已满足；移动位因声明不支持移动端，按要求提交 0 张。

截图 4 需特别注意：验收脚本走容器直连取图时页面不带注入脚本（验收日志会显示「注入 0 个」），那种图里账号密码框是空的，不能当素材。这张是从真实域名 `https://flycms.wans.heiyu.space/admin/` 拍的，账号 `flycms` 与密码已由注入自动填好、验证码留空待手输、无红框报错。

---

## 三、更新日志（publish 用）

见 `/tmp/flycms-changelog.md`，提审命令会直接引用。

---

## 四、审核可能问的「已有同类」回应

商店现有 `cloud.lazycat.app.misago`（论坛）与 `cloud.lazycat.app.candy-bbs`（社区）两个同类，审核可能要求说明差异：

```
FlyCms 与 misago / candy-bbs 的使用场景不同。

misago 与 candy-bbs 是社区论坛：以「用户发帖、楼中楼、版块与权限」为中心，核心价值是让多人在站内互动。

FlyCms 是单主体的建站系统：以「站长发布运营内容」为中心，提供频道树（栏目）、文章与自定义内容模型（文章 / 相册 / 视频 / 单页）、留言板、友链与站内搜索，面向企业官网、部门信息门户、个人站点这类「一个人维护、访客阅读」的场景，不需要注册用户即可使用。

也就是说：FlyCms 没有论坛的版块与用户权限体系，misago 没有 CMS 的栏目树与内容模型。两者不是同一品类的替代关系。
```

---

## 五、提审操作

1. 你执行 `lzc-cli appstore login`（交互式，需要你的开发者账号）。
2. 在开发者中心创建应用 `cloud.lazycat.app.flycms`，填上面第一节的字段、上传第二节的素材。
3. 告诉我登录好了，我执行：

```
cd /home/wans/flycms-lzcapp
lzc-cli appstore publish /tmp/flycms-build/application.lpk \
  -c "$(cat /tmp/flycms-changelog.md)" --clang zh
```

注意：`lzc-cli appstore publish` **没有建应用的选项**，包名必须先在开发者中心存在，否则会失败。若想省掉手工建应用，改走 GitHub Action 的 `create_if_missing: true`（需要把开发者 token 作为仓库 Secret `LZC_API_TOKEN`），但那条路要么有 token、要么得先登录一次，绕不开凭据。

---

## 六、本轮验收结论

`scripts/box-accept.mjs --fresh-data` 全新数据卷验收 19 步全绿：卸载 → 清空 `/lzcsys/data/appvar/cloud.lazycat.app.flycms` → 安装 → 5 容器 Up → 首次初始化导入 84 张表 + 29 条迁移 + 演示内容 → 入口页 200 → 28 页回归 0 报错 → 4 张截图 → 探针 6 项断言（`/api/health`、`/api/ready`、中文编码、注入脚本）全过。

平台侧另有一处须注意：应用对不存在的短链返回 **200 软 404**（渲染空态页而非 404 页），与本包打包无关，属上游行为，已在 `NOTES.md` §19 记录。
