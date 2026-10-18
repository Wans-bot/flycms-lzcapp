#!/bin/bash
# FlyCms 首次初始化（幂等）：等 MySQL 就绪 → 建库 → 导入上游基础 SQL → 写 done 标记并常驻。
#
# 上游 SQL 来自 sql/flycms_20260928_093335.sql（MySQL 5.7.44 导出，84 表，535 条 INSERT），
# 文件里没有 CREATE DATABASE 也没有 USE，所以库要自己建。
set -u

HOST="${LZC_DB_HOST:-flycms-db}"
USER="${LZC_DB_USER:-root}"
SQL="${LZC_SQL_FILE:-/lzcapp/pkg/content/sql/flycms.sql}"
DB="${LZC_DB_NAME:-flycms}"
DONE=/tmp/init-db.done
log() { echo "[flycms-init] $*"; }

for i in $(seq 1 120); do
  if mysqladmin ping -h "$HOST" -u"$USER" --silent 2>/dev/null; then
    log "MySQL 已就绪（第 ${i} 次探测）"
    break
  fi
  sleep 3
done

# 上游 dump 混用 utf8 与 utf8mb4，MySQL 8 对 utf8mb3 仍兼容，这里统一库级 utf8mb4
mysql -h "$HOST" -u"$USER" -e \
  "CREATE DATABASE IF NOT EXISTS \`${DB}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;" \
  2>&1 | tail -3

exists=$(mysql -h "$HOST" -u"$USER" -N -B -e \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB}' AND table_name='fly_admin';" 2>/dev/null || echo "err")

if [ "$exists" = "1" ]; then
  log "检测到已有 fly_admin 表，跳过导入"
elif [ "$exists" = "err" ]; then
  log "查询表结构失败，仍写标记保持容器健康，由人工排查"
else
  log "导入 $SQL"
  if mysql -h "$HOST" -u"$USER" "$DB" < "$SQL" 2>&1 | tail -5; then
    log "导入命令返回成功"
  else
    log "导入失败（详见上面输出）"
  fi
fi

final=$(mysql -h "$HOST" -u"$USER" -N -B -e \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB}';" 2>/dev/null || echo "err")
log "${DB} 库表数量：$final"

date > "$DONE"

while true; do sleep 3600; done
