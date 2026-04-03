#!/bin/bash

# Скрипт полного выполнения лабораторной работы №2
echo "=== Подготовка окружения ==="
docker-compose down -v
docker-compose up -d

echo "Ожидание запуска СУБД (15 сек)..."
sleep 15

echo "Копирую скрипты в контейнеры для обхода macOS-прав..."
docker cp ./scripts pg_primary:/
docker exec pg_primary chmod +x -R /scripts
docker cp ./scripts pg_backup:/
docker exec pg_backup chmod +x -R /scripts

echo "Инициализация БД на основном узле..."
docker exec pg_primary psql -U postgres -c "CREATE DATABASE lab_db;" || true
docker exec pg_primary mkdir -p /var/lib/postgresql/tablespace1
docker exec pg_primary chown -R postgres:postgres /var/lib/postgresql/tablespace1
docker exec pg_primary psql -U postgres -d lab_db -f /scripts/init.sql

echo "Настройка pg_hba.conf для потоковой репликации/бэкапов..."
docker exec pg_primary sh -c "echo 'host replication all all trust' >> /var/lib/postgresql/data/pg_hba.conf"
docker exec pg_primary sh -c "echo 'host all all all trust' >> /var/lib/postgresql/data/pg_hba.conf"
docker exec pg_primary psql -U postgres -c "SELECT pg_reload_conf();"

echo "=== Этап 1: Резервное копирование ==="
# Выполняем полное резервное копирование, вызывая созданный скрипт изнутри резервного узла
docker exec pg_backup /scripts/backup_run.sh
echo "Проверка созданного бэкапа:"
docker exec pg_backup ls -lhR /backups

# Найдём файл бэкапа для последующего использования в переменных
BACKUP_DIR=$(docker exec pg_backup sh -c "ls -1d /backups/backup_* | head -n 1")
echo "Будет использоваться папка бэкапа: $BACKUP_DIR"

echo "=== Этап 4: Логическое повреждение данных ==="
echo "Добавляем новые данные:"
docker exec pg_primary psql -U postgres -d lab_db -c "INSERT INTO test_data (info) VALUES ('New valid data 1'), ('New valid data 2');"
docker exec pg_primary psql -U postgres -d lab_db -c "SELECT * FROM test_data;"

echo "Снимаем логический дамп (состояние до ошибки) с помощью pg_dump на резервном:"
docker exec pg_backup sh -c "PGPASSWORD=secretpassword pg_dump -h pg_primary -U postgres -d lab_db -t test_data -a > /backups/test_data_dump.sql"

echo "Симулируем ошибку (перезапись 'мусором'):"
docker exec pg_primary psql -U postgres -d lab_db -c "UPDATE test_data SET info = 'GARBAGE DATA';"
docker exec pg_primary psql -U postgres -d lab_db -c "SELECT * FROM test_data;"

echo "Восстанавливаем данные из дампа на основном узле:"
# Для применения дампа сначала очистим таблицу
docker exec pg_primary psql -U postgres -d lab_db -c "TRUNCATE test_data;"
# Передаём дамп напрямую через пайп из резервного контейнера в основной
docker exec pg_backup cat /backups/test_data_dump.sql | docker exec -i pg_primary psql -U postgres -d lab_db
echo "Проверка восстановленных данных:"
docker exec pg_primary psql -U postgres -d lab_db -c "SELECT * FROM test_data ORDER BY id;"

echo "=== Этап 3: Повреждение файлов БД ==="
echo "Определяем OID базы lab_db и таблицы test_data"
DB_OID=$(docker exec pg_primary psql -U postgres -c "SELECT oid FROM pg_database WHERE datname='lab_db';" -t -A)
REL_OID=$(docker exec pg_primary psql -U postgres -d lab_db -c "SELECT relfilenode FROM pg_class WHERE relname='test_data';" -t -A)
echo "DB_OID: $DB_OID, REL_OID: $REL_OID"

echo "Удаляем файл таблицы test_data..."
docker exec pg_primary rm -f /var/lib/postgresql/data/base/$DB_OID/$REL_OID

echo "Проверяем доступность (должна быть ошибка):"
docker exec pg_primary psql -U postgres -d lab_db -c "SELECT * FROM test_data;" || echo "Ошибка доступа к файлу - ожидаемо"

echo "Останавливаем СУБД на основном узле..."
docker stop pg_primary

echo "Восстанавливаем из бэкапа..."
BACKUP_DIR_NAME=$(basename $BACKUP_DIR)
BACKUP_VOL=$(docker inspect pg_backup -f '{{ range .Mounts }}{{ if eq .Destination "/backups" }}{{ .Name }}{{ end }}{{ end }}')

# Сценарий восстановления для Stage 3:
# Исходный tablespace был в /var/lib/postgresql/tablespace1.
# Эмулируем, что старая директория умерла, распаковываем в /var/lib/postgresql/tablespace2 и меняем симлинк.
docker run --rm -v $BACKUP_VOL:/backups --volumes-from pg_primary ubuntu bash -c "
  cd /backups/$BACKUP_DIR_NAME
  rm -rf /var/lib/postgresql/data/*
  rm -rf /var/lib/postgresql/tablespace1
  mkdir -p /var/lib/postgresql/data/pg_wal
  mkdir -p /var/lib/postgresql/tablespace2
  chown -R 999:999 /var/lib/postgresql/tablespace2

  tar -xzf base.tar.gz -C /var/lib/postgresql/data
  tar -xzf pg_wal.tar.gz -C /var/lib/postgresql/data/pg_wal || true

  for ts in *.tar.gz; do
    if [ \"\$ts\" != \"base.tar.gz\" ] && [ \"\$ts\" != \"pg_wal.tar.gz\" ]; then
      TS_ID=\${ts%.tar.gz}
      tar -xzf \$ts -C /var/lib/postgresql/tablespace2
      # Корректировка конфигурации путей табличных пространств:
      ln -sfn /var/lib/postgresql/tablespace2 /var/lib/postgresql/data/pg_tblspc/\$TS_ID
    fi
  done
  chown -h 999:999 /var/lib/postgresql/data/pg_tblspc/* || true
  chown -R 999:999 /var/lib/postgresql/data
"

echo "Запускаем СУБД на основном узле..."
docker start pg_primary
echo "Ожидание запуска СУБД после восстановления файлов (10 сек)..."
sleep 10
echo "Проверка доступности после восстановления файлов:"
# т.к. бэкап делался ДО добавления "New valid data", то тут мы должны видеть 3 записи "Initial data"
docker exec pg_primary psql -U postgres -d lab_db -c "SELECT * FROM test_data;"
echo "Проверка доступности данных из альтернативного tablespace:"
docker exec pg_primary psql -U postgres -d lab_db -c "SELECT * FROM test_data_ts;"

echo "=== Этап 2: Потеря основного узла ==="
echo "Останавливаем основной узел навсегда:"
docker stop pg_primary

echo "Распаковываем бэкап в директорию данных резервного узла..."
docker stop pg_backup
docker run --rm -v $BACKUP_VOL:/backups --volumes-from pg_backup ubuntu bash -c "
  cd /backups/$BACKUP_DIR_NAME
  rm -rf /var/lib/postgresql/data/*
  tar -xzf base.tar.gz -C /var/lib/postgresql/data
  mkdir -p /var/lib/postgresql/data/pg_wal
  tar -xzf pg_wal.tar.gz -C /var/lib/postgresql/data/pg_wal || true
  
  mkdir -p /var/lib/postgresql/tablespace2
  chown -R 999:999 /var/lib/postgresql/tablespace2
  for ts in *.tar.gz; do
    if [ \"\$ts\" != \"base.tar.gz\" ] && [ \"\$ts\" != \"pg_wal.tar.gz\" ]; then
      TS_ID=\${ts%.tar.gz}
      tar -xzf \$ts -C /var/lib/postgresql/tablespace2
      ln -sfn /var/lib/postgresql/tablespace2 /var/lib/postgresql/data/pg_tblspc/\$TS_ID
    fi
  done
  chown -h 999:999 /var/lib/postgresql/data/pg_tblspc/* || true
  chown -R 999:999 /var/lib/postgresql/data
"

echo "Перезапускаем резервный узел для старта с восстановленными данными..."
docker restart pg_backup
echo "Ожидание запуска СУБД на резерве (10 сек)..."
sleep 10

echo "Проверка доступности данных на резервном узле:"
docker exec pg_backup psql -U postgres -d lab_db -c "SELECT * FROM test_data;"

echo "=== Завершено ==="
