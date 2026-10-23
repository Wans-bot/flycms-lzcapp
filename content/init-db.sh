#!/bin/bash
# FlyCms 首次初始化：等 MySQL 就绪 → 按 schema 版本决定是否整库重建 → 应用全部迁移 → 校验关键列 → 常驻。
#
# 为什么用「版本号 + 整库重建」而不是逐条增量判断：
# 上游基线 sql/flycms.sql 是 2026-09-28 09:33 导出的，比 master 落后 29 个迁移，
# 逐条判断会留下「表在了但列没补齐」的半状态（实测踩到 use_content、relate_model、is_unique 三次）。
# 这里把基线 + 全部迁移视作一个整体，用 LZC_SCHEMA_REV 标记它的版本：
#   rev 6：带上上游 27 个迁移 + 999 兜底补列（fly_model_field 缺 min_value/formula 等会让首页 500）
#   * 库里的 rev 与当前脚本不一致 → 整库重建后重放全部迁移（确定性）；
#   * 一致 → 直接常驻，不重放（重启不会插重复数据）。
set -u -o pipefail

HOST="${LZC_DB_HOST:-flycms-db}"
USER="${LZC_DB_USER:-root}"
SQL="${LZC_SQL_FILE:-/lzcapp/pkg/content/sql/flycms.sql}"
SQL_DIR="$(dirname "$SQL")"
# 迁移目录有两个可能位置：sql/migrations/ 与直接平铺在 sql/ 下（0*.sql）。
# 原因：CI 里打包 content 用的新打包器会把 sql/migrations/ 这种二级子目录整个漏掉
# （2026-10-22 实测：本地 lzc-cli 打得出、GitHub Action 打出来的包里没有），
# 所以迁移文件同时平铺一份到 sql/ 下，这里两处都扫，重复执行靠 IF NOT EXISTS 兜住。
MIG_DIR="${LZC_MIGRATION_DIR:-$SQL_DIR/migrations}"
DB="${LZC_DB_NAME:-flycms}"
DONE=/tmp/init-db.done
# 改动基线或迁移后必须递增，容器重启时才会按新版本重建。
REV="${LZC_SCHEMA_REV:-6}"
EXPECTED="${LZC_EXPECTED_TABLES:-80}"
STATE=fly_lzc_schema_state
log() { echo "[flycms-init] $*"; }

mysql_q() { mysql --default-character-set=utf8mb4 -h "$HOST" -u"$USER" -N -B "$@"; }

table_count() {
  mysql_q -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB}';" 2>/dev/null || echo "err"
}

for i in $(seq 1 120); do
  if mysqladmin ping -h "$HOST" -u"$USER" --silent 2>/dev/null; then
    log "MySQL 已就绪（第 ${i} 次探测）"
    break
  fi
  sleep 3
done

cur_rev=$(mysql_q -e "SELECT rev FROM \`${DB}\`.\`${STATE}\` LIMIT 1;" 2>/dev/null || true)
tables=$(table_count)
log "库表数量：${tables}；库内 schema rev=${cur_rev:-<无>}；本次需要 rev=${REV}"

if [ "$cur_rev" = "$REV" ] && [ "$tables" != "err" ] && [ "$tables" -ge "$EXPECTED" ] 2>/dev/null; then
  log "schema 已是 rev ${REV}，跳过重建与迁移"
else
  log "需要重建：DROP + 导入基线 + 重放迁移"
  mysql -h "$HOST" -u"$USER" -e "DROP DATABASE IF EXISTS \`${DB}\`;" >/dev/null 2>&1 || true
  # 上游 dump 混用 utf8 与 utf8mb4；库级统一 utf8mb4
  mysql -h "$HOST" -u"$USER" -e \
    "CREATE DATABASE IF NOT EXISTS \`${DB}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;" \
    >/dev/null 2>&1 || true

  log "导入 ${SQL}"
  # 输出落盘再看退出码：管道接 tail 会把 tail 的状态当成 mysql 的状态。
  # --force：基线是上游 2026-09-28 导出的 2.9MB dump，曾因 `'true'`/`'false'` 写进 tinyint
  # 列在严格模式下报 ERROR 1366 而整库建不起来（2026-10-22 实机验收）。字面量已改 1/0，
  # 这里再兜一层：历史 dump 里若还有别的隐式转换错误，也让导入走完；真缺表由下面的
  # base_tables < EXPECTED 校验兜底。
  if mysql --force --default-character-set=utf8mb4 -h "$HOST" -u"$USER" "$DB" < "$SQL" > /tmp/flycms-import.log 2>&1; then
    log "基线导入成功"
  else
    log "基线导入失败，末尾 20 行："
    tail -20 /tmp/flycms-import.log
  fi

  base_tables=$(table_count)
  log "基线表数量：${base_tables}（下限 ${EXPECTED}）"
  if [ "$base_tables" = "err" ] || [ "$base_tables" -lt "$EXPECTED" ] 2>/dev/null; then
    # fail closed：不写 done 标记，healthcheck 保持失败，容器重启后重试；不会带着残库对外服务。
    log "基线不完整，退出以触发重建"
    exit 1
  fi

  for f in "$MIG_DIR"/*.sql "$SQL_DIR"/0*.sql; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    # 迁移里是 ADD COLUMN / CREATE TABLE IF NOT EXISTS，重复执行报 1060/1017 属正常，用 --force 跳过。
    if mysql --force -h "$HOST" -u"$USER" "$DB" < "$f" > "/tmp/mig-${base}.log" 2>&1; then
      log "迁移完成：${base}"
    else
      log "迁移有报错（可能仅重复列）：${base}，末尾 5 行："
      tail -5 "/tmp/mig-${base}.log"
    fi
  done

  # 关键列校验：门户首页读 fly_model.use_content，
  # 模型字段列表读 fly_model_field.relate_model / is_unique，缺一就 500。
  ok=$(mysql_q -e \
    "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='${DB}' AND ((table_name='fly_model' AND column_name='use_content') OR (table_name='fly_model_field' AND column_name IN ('relate_model','is_unique')));" \
    2>/dev/null || echo 0)
  if [ "$ok" = "3" ]; then
    log "关键列校验通过：use_content + relate_model + is_unique"
  else
    log "关键列校验失败（命中 ${ok}/3），退出以触发重建"
    exit 1
  fi

  mysql -h "$HOST" -u"$USER" "$DB" -e \
    "CREATE TABLE IF NOT EXISTS \`${STATE}\` (\`rev\` varchar(32) NOT NULL, \`applied_at\` datetime NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
     DELETE FROM \`${STATE}\`;
     INSERT INTO \`${STATE}\` (\`rev\`,\`applied_at\`) VALUES ('${REV}', NOW());" >/dev/null 2>&1 || true
  log "已登记 schema rev=${REV}"
fi

final=$(table_count)
log "最终表数量：${final}"
# 上游示例数据里带着别人的站点信息（页脚备案号、示例域名、SEO 文案）和一个端到端测试管理员账号。
# 这些会被审核当成应用方信息，也会让用户以为站点属于别人。用固定值覆盖，幂等，每次启动都执行。
cleanup_upstream() {
  if mysql -h "$HOST" -u"$USER" "$DB" >/dev/null 2>&1 <<'SQL'
UPDATE `fly_config_web` SET `keyvalue` = '' WHERE `keycode` IN ('fly_footer_code', 'fly_url');
UPDATE `fly_config_web` SET `keyvalue` = 'FlyCms' WHERE `keycode` = 'fly_seo_title';
UPDATE `fly_config_web` SET `keyvalue` = 'FlyCms' WHERE `keycode` = 'fly_seo_keywords';
UPDATE `fly_config_web` SET `keyvalue` = '' WHERE `keycode` = 'fly_seo_description';
DELETE FROM `fly_admin` WHERE `admin_name` <> 'flycms';
SQL
  then
    log "已清理上游示例痕迹（页脚备案号 / 示例域名 / SEO 文案 / 测试管理员）"
  else
    log "清理上游示例痕迹失败（不阻断启动，门户页脚可能仍显示上游信息）"
  fi
}

cleanup_upstream

# 部署适配：上游 SQL 导出时开着「模板调试条」（fly_config_web.template_debug=1），
# 前台每页左下角会浮出 `TPL · 模板文件 · 主题` 角标，暴露模板文件名与主题名，且会被当成调试版。
# TemplateResolver 在开关关闭时根本不暴露 __tpl，片段零输出，所以关掉即可，无需改模板。
mysql -h "$HOST" -u"$USER" "$DB" -e \
  "UPDATE fly_config_web SET keyvalue='0' WHERE keycode='template_debug';" >/dev/null 2>&1 \
  || log "关闭模板调试条失败（不致命）"

# 演示内容（部署适配）：上游自带的文章正文只有一行 <p>一句话</p>，另有两篇正文为空的
# 「定时发布验证稿 / 复测稿」和两篇同标题 0 阅读的重复副本。不补的话详情页会命中主题的
# 空态提示「本文暂无正文内容」，商店截图就变成一张空页。
# seed-demo.sql 删掉那 4 条无效数据、给剩下 12 篇补正文与摘要，并写入 fly_seed_marker 标记。
# 只在标记不存在时执行一次：用户后来在后台编辑过的正文不会被容器重启覆盖。
# 标记放在独立表 fly_seed_marker 而不是 fly_config_web —— 后者是应用的站点配置表，
# 加一行未知 keycode 会让后台「网站设置」页多出一个陌生字段。表不存在时 COUNT 会报错，
# 这里按「未补齐」处理（`|| echo 0`），正好让首次执行跑起来。
seeded=$(mysql -h "$HOST" -u"$USER" -N -B -e \
  "SELECT COUNT(*) FROM \`${DB}\`.fly_seed_marker WHERE k='demo_content_v2';" 2>/dev/null || echo 0)
seeded=$(echo "${seeded:-0}" | tr -d '[:space:]')
if [ "$seeded" = "0" ]; then
  log "补齐演示内容（seed-demo.sql）"
  # 同样落盘再看退出码：命令行不接管道，退出码才是 mysql 自己的。
  if mysql --default-character-set=utf8mb4 -h "$HOST" -u"$USER" "$DB" < /lzcapp/pkg/content/seed-demo.sql > /tmp/flycms-seed.log 2>&1; then
    log "演示内容已写入"
  else
    log "演示内容写入失败，日志末尾 15 行："
    tail -15 /tmp/flycms-seed.log
  fi
else
  log "演示内容已存在，跳过"
fi

date > "$DONE"
log "初始化完成，进入常驻"
while true; do sleep 3600; done
