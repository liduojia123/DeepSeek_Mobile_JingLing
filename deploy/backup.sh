#!/usr/bin/env bash
# 鲸灵服务器每日备份:SQLite 一致性快照 + 配置备份,保留最近 7 天。
# 安装:放到 /opt/jingling/backup.sh,cron: 30 3 * * * /opt/jingling/backup.sh
set -euo pipefail

BACKUP_DIR=/opt/jingling/backups
DATA_DIR=/opt/jingling/data
CONTAINER=jingling-jingling-1
STAMP=$(date +%Y%m%d-%H%M%S)
KEEP_DAYS=7

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

# 1) 用容器里的 better-sqlite3 做一致性备份(不能在运行中直接 cp)
sudo docker exec "$CONTAINER" node -e "
const Database = require('better-sqlite3');
const db = new Database('/app/data/jingling.db', { readonly: true });
db.backup('/app/data/jingling-backup.db').then(() => process.exit(0)).catch((error) => { console.error(error); process.exit(1); });
"

# 2) 拷贝并压缩
cp "$DATA_DIR/jingling-backup.db" "$BACKUP_DIR/jingling-$STAMP.db"
gzip -f "$BACKUP_DIR/jingling-$STAMP.db"
rm -f "$DATA_DIR/jingling-backup.db"

# 3) 配置与编排文件(含密钥,权限收紧)
cp /opt/jingling/.env "$BACKUP_DIR/env-$STAMP.bak"
cp /opt/jingling/docker-compose.yml "$BACKUP_DIR/compose-$STAMP.yml"
chmod 600 "$BACKUP_DIR"/env-*.bak

# 4) 清理旧备份(数据库 + 环境备份一起轮转)
find "$BACKUP_DIR" -name 'jingling-*.db.gz' -mtime +$KEEP_DAYS -delete
find "$BACKUP_DIR" -name 'env-*.bak' -mtime +$KEEP_DAYS -delete
find "$BACKUP_DIR" -name 'compose-*.yml' -mtime +$KEEP_DAYS -delete

echo "[$(date -Iseconds)] backup ok: jingling-$STAMP.db.gz ($(du -h "$BACKUP_DIR/jingling-$STAMP.db.gz" | cut -f1))"
