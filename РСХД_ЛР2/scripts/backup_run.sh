#!/bin/bash
# Запускается на резервном хосте (в контейнере или на хосте через docker exec)
# Выполняет полный pg_basebackup с основного узла и хранит архивы в /backups

set -euo pipefail
TIMESTAMP=$(date +%Y%m%d%H%M)
BACKUP_PATH=/backups/backup_${TIMESTAMP}

export PGPASSWORD=${PGPASSWORD:-secretpassword}
# Создаём папку, если нет
mkdir -p /backups

# Выполнить pg_basebackup: полная копия, включающая WAL (stream), в tar и сжатую.
# pg_basebackup создаст папку BACKUP_PATH и положит туда base.tar.gz и pg_wal.tar.gz
pg_basebackup -h pg_primary -U postgres -D "$BACKUP_PATH" -Ft -z -Xs -P

# Проверяем успешность
if [ $? -eq 0 ]; then
  echo "Backup saved to $BACKUP_PATH"
else
  echo "pg_basebackup failed" >&2
  exit 1
fi

# Очистка старых бэкапов на резерве (хранить 30 дней)
find /backups -maxdepth 1 -type d -name 'backup_*' -mtime +30 -exec rm -rf {} +

exit 0
