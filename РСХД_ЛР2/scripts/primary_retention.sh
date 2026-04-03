#!/bin/bash
# Скрипт удаляет локальные бэкапы на primary старше 7 дней
BACKUP_DIR=/backups_primary
mkdir -p "$BACKUP_DIR"
find "$BACKUP_DIR" -maxdepth 1 -type f -name 'base_*.tar.gz' -mtime +7 -print -delete
