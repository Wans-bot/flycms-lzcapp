#!/bin/bash
# FlyCms 首次初始化：等 MySQL 就绪 → 按 schema 版本决定是否整库重建 → 应用全部迁移 → 校验关键列 → 常驻。
#
# 为什么用「版本号 + 整库重建」而不是逐条增量判断：
# 上游基线 sql/flycms.sql 是 2026-09-28 09:33 导出的，比 master 落后 29 个迁移，
# 逐条判断会留下「表在了但列没补齐」的半状态（实测踩到 use_content、relate_model、is_unique 三次）。
# 这里把基线 + 全部迁移视作一个整体，用 LZC_SCHEMA_REV 标记它的版本：
#   * 库里的 rev 与当前脚本不一致 → 整库重建后重放全部迁移（确定性）；
#   * 一致 → 直接常驻，不重放（重启不会插重复数据）。
set -u -o pipefail

HOST="${LZC_DB_HOST:-flycms-db}"
USER="${LZC_DB_USER:-root}"
SQL="${LZC_SQL_FILE:-/lzcapp/pkg/content/sql/flycms.sql}"
MIG_DIR="${LZC_MIGRATION_DIR:-/lzcapp/pkg/content/sql/migrations}"
DB="${LZC_DB_NAME:-flycms}"
DONE=/tmp/init-db.done
# 改动基线或迁移后必须递增，容器重启时才会按新版本重建。
REV="${LZC_SCHEMA_REV:-3}"
EXPECTED="${LZC_EXPECTED_TABLES:-80}"
STATE=fly_lzc_schema_state
log() { echo "[flycms-init] $*"; }

mysql_q() { mysql -h "$HOST" -u"$USER" -N -B "$@"; }

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
  if mysql -h "$HOST" -u"$USER" "$DB" < "$SQL" > /tmp/flycms-import.log 2>&1; then
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

  for f in "$MIG_DIR"/*.sql; do
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
date > "$DONE"
log "初始化完成，进入常驻"
while true; do sleep 3600; done
