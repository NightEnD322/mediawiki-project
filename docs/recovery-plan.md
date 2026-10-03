# План аварийного восстановления MediaWiki

## 1. Назначение

Документ описывает восстановление корпоративного сервиса MediaWiki при отказе компонентов инфраструктуры.

Рассматриваются:

- отказ одной application-ноды;
- отказ PostgreSQL standby;
- отказ PostgreSQL primary;
- восстановление потоковой репликации;
- отказ edge-ops;
- восстановление из резервных копий.

## 2. Топология

| Узел | Внутренний IP | Назначение |
|---|---|---|
| edge-ops | 10.20.1.17 | Nginx LB, NFS, Zabbix, backups |
| app1 | 10.20.1.5 | MediaWiki, Nginx, PHP-FPM |
| app2 | 10.20.2.34 | MediaWiki, Nginx, PHP-FPM |
| db1 | 10.20.1.29 | PostgreSQL primary или standby |
| db2 | 10.20.2.10 | PostgreSQL primary или standby |

Текущая топология PostgreSQL хранится в:

```text
ansible/group_vars/all/vars.yml
```

На момент составления документа:

```yaml
postgresql_primary_host: db1
postgresql_primary_ip: "10.20.1.29"

postgresql_standby_host: db2
postgresql_standby_ip: "10.20.2.10"
```

## 3. Определение ролей PostgreSQL

```bash
ssh mw-db1 '
sudo -u postgres psql -d postgres -Atc \
"SELECT pg_is_in_recovery();"
'

ssh mw-db2 '
sudo -u postgres psql -d postgres -Atc \
"SELECT pg_is_in_recovery();"
'
```

Результаты:

- `f` — primary;
- `t` — standby.

Проверка репликации выполняется на primary:

```bash
sudo -u postgres psql -d postgres -c \
"SELECT application_name,
        client_addr,
        state,
        sync_state,
        write_lag,
        flush_lag,
        replay_lag
 FROM pg_stat_replication;"
```

Исправная реплика должна иметь:

```text
state = streaming
sync_state = async
```

## 4. Резервное копирование

### Расписание

Файлы MediaWiki:

```text
ежедневно в 02:00 UTC
```

PostgreSQL:

```text
каждые 6 часов: 00:00, 06:00, 12:00, 18:00 UTC
```

Срок хранения:

```text
14 дней
```

Пропущенные задания выполняются после запуска VM благодаря:

```ini
Persistent=true
```

### Проверка таймеров

```bash
ssh mw-edge '
systemctl list-timers --all "mediawiki-*"
'
```

### Ручной запуск дампа PostgreSQL

```bash
ssh mw-edge '
sudo systemctl start mediawiki-backup@database.service

sudo systemctl status \
  mediawiki-backup@database.service \
  --no-pager -l
'
```

### Ручной запуск файлового архива

```bash
ssh mw-edge '
sudo systemctl start mediawiki-backup@files.service

sudo systemctl status \
  mediawiki-backup@files.service \
  --no-pager -l
'
```

Каталоги:

```text
/srv/mediawiki-data/backups/database
/srv/mediawiki-data/backups/filesystem
```

## 5. Отказ app1 или app2

При отказе одного backend Nginx направляет запросы на исправную application-ноду.

Проверка:

```bash
ssh mw-edge '
for i in 1 2 3; do
  curl --max-time 15 -sS -o /dev/null \
    -w "Запрос $i: HTTP %{http_code}, %{time_total}s\n" \
    http://127.0.0.1/index.php
done
'
```

Ожидается:

```text
HTTP 200
```

### Восстановление application-ноды

```bash
cd ~/mediawiki-project/ansible

ansible app1 \
  -m wait_for_connection \
  -a 'timeout=120 sleep=5' \
  --ask-vault-pass
```

Для второй ноды используется имя `app2`.

Восстановление конфигурации:

```bash
ansible-playbook site.yml \
  --ask-vault-pass
```

Проверка:

```bash
ssh mw-app1 '
systemctl is-active \
  nginx \
  php8.1-fpm \
  zabbix-agent

findmnt -T /var/www/mediawiki/images

curl -sS -o /dev/null \
  -w "HTTP %{http_code}\n" \
  http://127.0.0.1/index.php
'
```

## 6. Отказ PostgreSQL standby

Отказ standby не останавливает MediaWiki. Сервис продолжает работать с primary.

Standby восстанавливается командой:

```bash
cd ~/mediawiki-project/ansible

ansible-playbook rebuild-standby.yml \
  --ask-vault-pass \
  -e confirm_rebuild=true
```

Плейбук:

1. проверяет текущую primary;
2. определяет standby;
3. проверяет существующую конфигурацию реплики;
4. останавливает PostgreSQL на повреждённой standby;
5. удаляет старый каталог данных;
6. выполняет `pg_basebackup`;
7. создаёт standby-конфигурацию;
8. запускает PostgreSQL;
9. проверяет recovery mode;
10. ожидает состояние `streaming`.

Если standby уже исправна и подключена к текущей primary, повторное удаление данных не выполняется.

## 7. Отказ PostgreSQL primary

### Изоляция старой primary

Перед продвижением standby старая primary должна быть остановлена или изолирована.

Это обязательное условие для защиты от split-brain.

Пример остановки db1:

```bash
yc compute instance stop mediawiki-db1 \
  --folder-id b1gbmki16lo7b6kciivc
```

Проверка:

```bash
yc compute instance list \
  --folder-id b1gbmki16lo7b6kciivc
```

Старая primary должна иметь состояние:

```text
STOPPED
```

### Продвижение standby

Пример переключения с db1 на db2:

```bash
cd ~/mediawiki-project/ansible

ansible-playbook promote-primary.yml \
  --ask-vault-pass \
  -e new_primary_host=db2 \
  -e old_primary_host=db1
```

Плейбук:

- проверяет переданные имена узлов;
- проверяет недоступность старой primary;
- продвигает standby;
- обновляет `pg_hba.conf`;
- записывает новую топологию в `group_vars/all/vars.yml`;
- переключает обе MediaWiki-ноды;
- перезапускает PHP-FPM;
- переключает резервное копирование;
- проверяет MediaWiki на каждом app-узле;
- проверяет MediaWiki через load balancer.

### Проверка новой primary

```bash
ssh mw-db2 '
sudo -u postgres psql -d postgres -Atc \
"SELECT pg_is_in_recovery();"
'
```

Ожидается:

```text
f
```

Проверка MediaWiki:

```bash
ssh mw-edge '
curl --max-time 15 -sS -o /dev/null \
  -w "MediaWiki: HTTP %{http_code}, %{time_total}s\n" \
  http://127.0.0.1/index.php
'
```

### Возврат старой primary

Старый узел запрещено запускать как самостоятельную primary после переключения.

Во время контролируемого теста перед остановкой старого узла необходимо отключить автоматический запуск PostgreSQL:

```bash
ssh mw-db1 '
sudo systemctl disable postgresql

echo "enabled: $(systemctl is-enabled postgresql || true)"
echo "active: $(systemctl is-active postgresql)"
'
```

После запуска VM ожидается:

```text
enabled: disabled
active: inactive
```

Затем узел пересоздаётся как standby:

```bash
ansible-playbook rebuild-standby.yml \
  --ask-vault-pass \
  -e confirm_rebuild=true
```

После восстановления PostgreSQL должен быть:

```text
enabled
active
```

## 8. Проверка репликации после восстановления

На primary:

```bash
sudo -u postgres psql -d postgres -c \
"SELECT application_name,
        client_addr,
        state,
        sync_state
 FROM pg_stat_replication;"
```

Ожидается:

```text
state = streaming
sync_state = async
```

На standby:

```bash
sudo -u postgres psql -d postgres -Atc \
"SELECT pg_is_in_recovery();"
```

Ожидается:

```text
t
```

## 9. Проверка MediaWiki после failover

Проверка адреса БД:

```bash
for node in mw-app1 mw-app2; do
  echo "=== $node ==="

  ssh "$node" '
    sudo grep -n "\$wgDBserver" \
      /var/www/mediawiki/LocalSettings.php

    curl --max-time 15 -sS -o /dev/null \
      -w "HTTP %{http_code}, %{time_total}s\n" \
      http://127.0.0.1/index.php
  '
done
```

Проверка балансировщика:

```bash
ssh mw-edge '
for i in 1 2 3; do
  curl --max-time 15 -sS -o /dev/null \
    -w "LB запрос $i: HTTP %{http_code}, %{time_total}s\n" \
    http://127.0.0.1/index.php
done
'
```

## 10. Проверка резервного копирования после failover

Проверка адреса primary в скрипте:

```bash
ssh mw-edge '
sudo grep -n "^DB_HOST=" \
  /usr/local/sbin/mediawiki-database-backup
'
```

Запуск:

```bash
ssh mw-edge '
sudo systemctl start \
  mediawiki-backup@database.service

sudo systemctl status \
  mediawiki-backup@database.service \
  --no-pager -l
'
```

Ожидается:

```text
status=0/SUCCESS
```

## 11. Проверка дампа PostgreSQL

Поиск последнего дампа:

```bash
ssh mw-edge '
sudo find \
  /srv/mediawiki-data/backups/database \
  -maxdepth 1 \
  -type f \
  -name "mediawiki-db-*.dump" \
  -printf "%TY-%Tm-%Td %TH:%TM %p\n" |
sort |
tail
'
```

Дамп проверяется восстановлением во временную базу:

```bash
sudo -u postgres createdb \
  my_wiki_restore_test

sudo -u postgres pg_restore \
  --dbname=my_wiki_restore_test \
  /path/to/mediawiki-db-backup.dump
```

Проверка страниц:

```bash
sudo -u postgres psql \
  -d my_wiki_restore_test \
  -c \
  "SELECT page_id, page_title
   FROM mediawiki.page
   ORDER BY page_id;"
```

Удаление тестовой базы:

```bash
sudo -u postgres dropdb \
  my_wiki_restore_test
```

Рабочая база не удаляется во время тестовой проверки.

## 12. Проверка файлового архива

Поиск архива:

```bash
ssh mw-edge '
sudo find \
  /srv/mediawiki-data/backups/filesystem \
  -maxdepth 1 \
  -type f \
  -name "mediawiki-files-*.tar.gz" \
  -printf "%TY-%Tm-%Td %TH:%TM %p\n" |
sort |
tail
'
```

Проверка целостности:

```bash
ssh mw-edge '
sudo tar -tzf \
  /srv/mediawiki-data/backups/filesystem/mediawiki-files-YYYY-MM-DD_HH-MM-SS.tar.gz \
  >/dev/null &&
echo "Архив читается"
'
```

Перед восстановлением рабочей директории архив рекомендуется сначала распаковать во временный каталог.

## 13. Отказ edge-ops

`edge-ops` выполняет следующие функции:

- публичный Nginx load balancer;
- NFS-сервер;
- Zabbix server;
- web-интерфейс Zabbix;
- сервер резервного копирования.

Полный отказ `edge-ops` приводит к недоступности публичного входа и общего NFS.

### Восстановление инфраструктуры

```bash
cd ~/mediawiki-project/terraform

terraform validate
terraform plan
terraform apply
```

Terraform должен восстановить VM и подключить существующий дополнительный диск.

### Восстановление конфигурации

```bash
cd ~/mediawiki-project/ansible

ansible edge-ops \
  -m wait_for_connection \
  -a 'timeout=120 sleep=5' \
  --ask-vault-pass

ansible-playbook site.yml \
  --ask-vault-pass
```

### Проверка edge-ops

```bash
ssh mw-edge '
echo "=== DATA DISK ==="
findmnt /srv/mediawiki-data

echo "=== SERVICES ==="
systemctl is-active \
  nginx \
  nfs-kernel-server \
  postgresql \
  apache2 \
  zabbix-server \
  zabbix-agent

echo "=== MEDIAWIKI ==="
curl -sS -o /dev/null \
  -w "HTTP %{http_code}\n" \
  http://127.0.0.1/index.php

echo "=== ZABBIX ==="
curl -sS -o /dev/null \
  -w "HTTP %{http_code}\n" \
  http://127.0.0.1/zabbix/
'
```

## 14. Проверка NFS

Создание файла на app1:

```bash
ssh mw-app1 '
sudo -u www-data touch \
  /var/www/mediawiki/images/.nfs-test
'
```

Проверка на app2:

```bash
ssh mw-app2 '
sudo test -f \
  /var/www/mediawiki/images/.nfs-test &&
echo "NFS shared write/read: OK"
'
```

Удаление:

```bash
ssh mw-app1 '
sudo -u www-data rm \
  /var/www/mediawiki/images/.nfs-test
'
```

## 15. Целевые показатели восстановления

| Данные | RPO |
|---|---|
| PostgreSQL при исправной standby | Минимальный, зависит от асинхронной репликации |
| PostgreSQL только из резервной копии | До 6 часов |
| Файлы MediaWiki только из резервной копии | До 24 часов |

RTO не гарантируется автоматически, поскольку продвижение PostgreSQL и восстановление `edge-ops` выполняются оператором.

## 16. Проверенные сценарии

В рамках проекта проверены:

- остановка app1;
- работа MediaWiki через app2;
- восстановление app1;
- автоматический запуск Nginx и PHP-FPM;
- автоматическое подключение NFS;
- загрузка изображения в MediaWiki;
- доступ к одному изображению через обе app-ноды;
- остановка PostgreSQL primary;
- продвижение standby;
- переключение MediaWiki;
- переключение резервного копирования;
- пересоздание старой primary как standby;
- восстановление состояния `streaming`;
- повторный запуск `rebuild-standby.yml` без удаления исправной реплики;
- создание дампа после failover;
- тестовое восстановление PostgreSQL;
- проверка файлового архива;
- повторный запуск `site.yml` с `changed=0`;
- `terraform plan` без изменений.

## 17. Ограничения

- PostgreSQL использует асинхронную репликацию. При внезапной потере primary возможна потеря последних транзакций.
- `edge-ops` остаётся единой точкой отказа для публичного входа и NFS.
- Рабочие данные NFS и локальные резервные копии находятся на одном дополнительном диске.
- Отказ дополнительного диска требует внешней копии, которая в учебной реализации не предусмотрена.
- Перед продвижением standby обязательна изоляция старой primary.
- Автоматическое продвижение standby не используется для защиты от ошибочного failover и split-brain.
