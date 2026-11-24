# ЛР5. Облачные базы данных. Amazon RDS (TimeCapsule)

- ФИО: Борденюк Иван (Bordeniuc Ivan)
- Группа: I2402
- Специальность: Informatică
- Уровень: продвинутый (Часть 1 + Часть 2, задания 1-12)
- Репозиторий: https://github.com/srulimoisovich-cloud/timecapsule (публичный)
- ADR: [0004. База в Amazon RDS (Single-AZ), а не на своём сервере](../adr/0004-database-hosting.md)
- Схема: [arch.png](arch.png)
- Прошлые отчёты: [ЛР2](../../README.md), [ЛР3](../lab3/README.md), [ЛР4](../lab4/README.md)

## Коротко

Учебная база `lab5-db` (PostgreSQL 18.3, Free tier) с репликой и восстановлением на момент времени, потом всё учебное удалено. База приложения `timecapsule-dev-rds` (PostgreSQL 16.12) приняла данные с `db-server` (users 2, capsules 2 в обеих), CNAME `db` переключён на неё, `db-server` удалён, новая капсула №4 записана в RDS. На ночь базу останавливает EventBridge Scheduler (`0 23 * * ? *`). Платного осталось немного: диск RDS в остановленном состоянии, Elastic IP `app`, зона Route 53, диски EBS.

Как сняты рисунки. Консоль AWS: настоящие снимки из Chrome (номер аккаунта и домашний IP закрыты). Терминал: настоящий вывод команд, нарисованный из логов. Группы доступа, группы подсетей, `lab5-tmp-web`, политику и роль расписания я создал командами (форма консоли для них ничего нового не показывает), а то, что задание велит показать в консоли (создание базы, реплика, восстановление, расписание), делал в консоли. Команды `psql`, `dig`, `curl` гонял с ноутбука через bastion: `ssh tmpweb '...'`, `ssh app '...'`.

Пароль `dbadmin` обеих баз сгенерировала RDS (`Auto generate password`), он лежит у меня в файле с правами 600 и в `~/.pgpass` на серверах; в отчёт и на рисунки не попадает.

Ограничения Free plan (аккаунт новый): только шаблон `Free tier` (это и есть `Sandbox` из задания), копии максимум 1 день, не больше двух экземпляров RDS одновременно. Где это повлияло, написано в тексте.

Теги на всём: `Name`, `Project=timecapsule`, `Environment=dev`, `Owner=ivanbordeniuc`, `Lab=lab5`, плюс `Team=solo`, `Stack=php`.

| Ресурс | Имя | Значение |
| --- | --- | --- |
| Учебная группа подсетей | `lab5-db-subnets` | `private-a` + `private-b` |
| SG клиента (учебный) | `lab5-clients-sg` | 22 только от `bastion-sg` |
| SG учебной базы | `lab5-rds-sg` | 5432 только от `lab5-clients-sg` |
| Учебный сервер | `lab5-tmp-web` | `t3.micro`, AL2023, `public-b`, `psql` 18 |
| Учебная база | `lab5-db` | PostgreSQL 18.3, `db.t4g.micro`, `eu-central-1a` |
| Группа подсетей базы | `timecapsule-dev-db-subnets` | `private-a` + `private-b` |
| SG базы | `timecapsule-dev-rds-sg` | 5432 только от `timecapsule-dev-web-sg` |
| База приложения | `timecapsule-dev-rds` | PostgreSQL 16.12, `db.t4g.micro`, `eu-central-1a`, endpoint `timecapsule-dev-rds.c3kam8ik49zn.eu-central-1.rds.amazonaws.com` |
| Политика расписания | `timecapsule-dev-rds-stop` | только `rds:StopDBInstance` на эту базу |
| Роль расписания | `timecapsule-dev-scheduler-role` | доверие: `scheduler.amazonaws.com` |
| Расписание | `timecapsule-dev-rds-nightly-stop` | `cron(0 23 * * ? *)`, `Europe/Chisinau` |

---

## Часть 1. Базовый уровень

### Задание 1. Размещение и доступ

Группа подсетей `lab5-db-subnets`, SG клиента `lab5-clients-sg` и SG базы `lab5-rds-sg` созданы из CLI, теги те же.

![subnet group](shots/lab5-subnet-group.jpg)

Группы подсетей и их зоны (CLI).

![lab5-subnet-group-console](shots/lab5-subnet-group-console.jpg)

Группа `lab5-db-subnets` в консоли RDS: две подсети в `1a` и `1b`.

![SG](shots/lab5-sg.jpg)

Правила: в `lab5-rds-sg` единственное правило 5432 с источником `lab5-clients-sg` (в выводе стоит её `sg-...`), в `lab5-clients-sg` ssh только от bastion.

![lab5-rds-sg-rules](shots/lab5-rds-sg-rules.jpg)

Входящие правила `lab5-rds-sg` в консоли EC2.

ответ: SG источника следует за серверами, а не за адресами: если сервер пересоздать или добавить второй, правило не трогаю, а IP пришлось бы править каждый раз (и он у публичных серверов меняется после остановки). Две подсети нужны, потому что RDS требует группу подсетей минимум из двух зон, даже когда база живёт в одной: так её можно будет восстановить во второй зоне и включить Multi-AZ без пересоздания группы.

### Задание 2. База `lab5-db`

Консоль, `Full configuration`, шаблон `Free tier`.

![lab5-create-1-template](shots/lab5-create-1-template.jpg)
![lab5-create-2-settings](shots/lab5-create-2-settings.jpg)
![lab5-create-3-storage](shots/lab5-create-3-storage.jpg)
![lab5-create-4-connectivity](shots/lab5-create-4-connectivity.jpg)
![lab5-create-5-backup](shots/lab5-create-5-backup.jpg)
![lab5-create-6-protection](shots/lab5-create-6-protection.jpg)
![lab5-db-available](shots/lab5-db-available.jpg)

Версия по умолчанию в форме: PostgreSQL 18.3-R2. Сначала поставил копии на 7 дней: `Create database` ответила `The specified backup retention period exceeds the maximum available to free tier customers`, оставил 1 день. Пароль выдала RDS (`Auto generate password`). Включил шифрование и `Deletion protection`, начальная база `lab5`, 7 тегов.

ответ: проверить доступ можно с обеих сторон: с `lab5-tmp-web` соединение идёт (задание 3), с ноутбука и с `app`, который не входит в `lab5-clients-sg`, порт молчит и `psql` упирается в таймаут (рисунок ниже); в SG базы при этом одно правило. Зона `eu-central-1a` потому, что там `public-a`, где живёт `app`: приложение и база в одной зоне не платят за межзонный трафик и не добавляют задержку, а резерва в другой зоне у Single-AZ всё равно нет. `Deletion protection` не даёт удалить экземпляр из консоли, CLI или скриптом по ошибке (сначала надо выключить флаг). От `DROP TABLE` и `DELETE`, от остановки базы, от неудачных миграций, а также от того, кто имеет право выключить флаг, она не защищает.

### Задание 3. Подключение

![psql](shots/lab5-p1-conn.jpg)

С `lab5-tmp-web`: `SELECT version()`, `\conninfo`, таблица `notes` и три строки.

![lab5-p1-dig-server](shots/lab5-p1-dig-server.jpg)
![lab5-p1-dig-laptop](shots/lab5-p1-dig-laptop.jpg)
![lab5-p1-deny](shots/lab5-p1-deny.jpg)

`dig` на сервере и на ноутбуке и попытка подключения с постороннего `app`.

`dig` и на сервере, и на ноутбуке вернул один и тот же приватный адрес `10.3.10.231`; с ноутбука `nc` на 5432 завис в таймауте, с `app` (не в `lab5-clients-sg`) `psql` тоже упёрся в таймаут (`exit=124`).

### Задание 4. Реплика

![lab5-replica-form](shots/lab5-replica-form.jpg)
![lab5-replica-available](shots/lab5-replica-available.jpg)
![lab5-p1-replica](shots/lab5-p1-replica.jpg)
![lab5-p1-fourth](shots/lab5-p1-fourth.jpg)
![lab5-replica-lag](shots/lab5-replica-lag.jpg)

Первая попытка создать реплику не прошла: `IAM role ARN value is invalid ... ENHANCED_MONITORING`, я снял `Enable Enhanced monitoring` и форма сработала. Реплика в `1b` стала Available примерно за 11 минут. `INSERT` в реплику даёт `cannot execute INSERT in a read-only transaction`, четвёртая строка с основной появилась на реплике через секунды. `ReplicaLag` в CloudWatch около 19 секунд.

ответ: реплика работает в режиме восстановления (`pg_is_in_recovery() = t`): она только применяет журнал основной базы и принимает чтение, а запись отвергает (`cannot execute INSERT in a read-only transaction`). Реплика для чтения асинхронная, у неё свой endpoint, она читаема и нужна, чтобы разгрузить основную базу; её можно повысить вручную. Резерв Multi-AZ синхронный, читать его нельзя, endpoint у пары один, и при отказе основной AWS переключает на него сама.

### Задание 5. Восстановление после ошибки

![lab5-p1-time](shots/lab5-p1-time.jpg)
![lab5-p1-delete](shots/lab5-p1-delete.jpg)
![lab5-latest-restore-time](shots/lab5-latest-restore-time.jpg)
![lab5-pitr-form-time](shots/lab5-pitr-form-time.jpg)
![lab5-pitr-form-network](shots/lab5-pitr-form-network.jpg)
![lab5-restore-available](shots/lab5-restore-available.jpg)
![lab5-p1-restored](shots/lab5-p1-restored.jpg)

Момент до ошибки: 06:00:27 UTC (`p1-time`), `DELETE` в 06:01:43 UTC. Форма восстановления работает в зоне UTC+2, поэтому ввёл 2026/11/24 08:00:25. `Latest restore time` догнал момент после удаления примерно через 7 минут (08:04:07 UTC+2), реплика к тому времени была удалена. Копия `lab5-db-restore` стала Available через 10 минут, в ней вернулись все 4 строки.

ответ: реплика повторяет все изменения основной почти сразу, включая ошибочный `DELETE`: через пару секунд таблица пуста и там. Реплика защищает от отказа сервера, а не от ошибки в данных. Восстановление создаёт новую базу, потому что запущенная база живёт на своём диске, а копия собирается из снимка и журнала на новых дисках на нужный момент: так можно сравнить обе, забрать нужные строки и не потерять то, что записано позже, а откатывать работающий экземпляр назад было бы опасно.

### Завершение Части 1

![lab5-databases-after-part1](shots/lab5-databases-after-part1.jpg)

Удалены без финальных снимков и без сохранения автобэкапов: `lab5-db-restore`, `lab5-db` (перед этим снял `Deletion protection`), реплика ещё раньше. Затем удалены `lab5-db-subnets`, `lab5-rds-sg`, `lab5-clients-sg`, `lab5-tmp-web` terminated. На рисунке список снимков без `lab5-` (ручных нет); в списке баз уже только создаваемая база приложения, потому что лимит Free plan разрешает её создавать лишь после удаления учебных.

---

## Часть 2. Продвинутый уровень

### Задание 6. База приложения

Группа подсетей `timecapsule-dev-db-subnets` и SG `timecapsule-dev-rds-sg` создал командами, базу формой консоли, после удаления учебных (лимит двух экземпляров).

![lab5-app-db-form-1](shots/lab5-app-db-form-1.jpg)
![lab5-app-db-form-2](shots/lab5-app-db-form-2.jpg)
![lab5-app-db-connectivity](shots/lab5-app-db-connectivity.jpg)

ответ: для боевой системы взял бы Multi-AZ (автопереключение, без потери данных), копии на 14-35 дней и снимок перед миграциями, класс без кредитов процессора (`db.m7g.large` или `t4g.small` в режиме unlimited), автоувеличение диска с потолком, Performance Insights, журналы PostgreSQL в CloudWatch и тревоги на CPU, память, место и число соединений. Пароль мастера держал бы в Secrets Manager с ротацией, а ночную остановку отключил бы: на проде база должна быть всегда.

### Задание 7. Ночная остановка

Политику и роль создал командами (файлы в `lab05/files`: политика с одним действием и одним ARN, доверие с `aws:SourceAccount`).

![iam](shots/lab5-iam.jpg)

![lab5-scheduler-policy](shots/lab5-scheduler-policy.jpg)
![lab5-scheduler-role-trust](shots/lab5-scheduler-role-trust.jpg)
![lab5-schedule-cron-test](shots/lab5-schedule-cron-test.jpg)
![lab5-schedule-target](shots/lab5-schedule-target.jpg)
![lab5-schedule-role](shots/lab5-schedule-role.jpg)
![lab5-schedule-created](shots/lab5-schedule-created.jpg)
![lab5-schedule-stopped-event](shots/lab5-schedule-stopped-event.jpg)

Тестовое выражение `cron(38 8 * * ? *)` (Europe/Chisinau), поле `Day of the week` дважды получило `??` и я его перепечатал. Расписание сработало в 08:38:28, `DB instance stopped` в 08:42 (около 4,5 минут). Затем отредактировал выражение на `0 23 * * ? *` и запустил базу: Available в 08:49, endpoint тот же.

ответ: расписание не вхожий в мою учётную запись сервис, действует только от роли: у него нет моих прав и не должно быть. Отдельная роль даёт именно то, что нужно, и ничего сверх (принцип наименьших прав), а брать её на себя может только `scheduler.amazonaws.com` из моего аккаунта. Роль остановит ровно одну базу, потому что в политике один action `rds:StopDBInstance` и один ARN `...:db:timecapsule-dev-rds`, без `*`: другую базу, запуск или удаление расписание не тронет, даже если его подменят.

### Задание 8. Пользователь и база

![user](shots/lab5-p2-user.jpg)

Пароль пользователя `timecapsule` скрипт берёт из `DB_PASSWORD` в `.env` и передаёт через `ALTER USER ... PASSWORD :'pw'` (на экран не выводится). `GRANT timecapsule TO dbadmin` нужен, чтобы `dbadmin` мог создать базу с владельцем `timecapsule`, затем `CREATE DATABASE timecapsule OWNER timecapsule`.

ответ: `dbadmin` может почти всё (создавать роли и базы, читать любую базу экземпляра), и пароль мастера нужен мне, а не коду. Если приложение работает под ним, одна SQL-инъекция или утёкший `.env` отдают весь экземпляр. Пользователь `timecapsule` владеет только своей базой, не может создавать роли и ходить в чужие базы, а его пароль можно менять отдельно, не трогая мастера.

### Задание 9. Перенос данных

![lab5-p2-migrate](shots/lab5-p2-migrate.jpg)

ответ приложения не открывал от выгрузки до переключения: `pg_dump` на `app`, загрузка в RDS; количества users 2 и capsules 2 в обеих базах совпали, дамп удалён..

### Задание 10. Переключение

![lab5-p2-dns](shots/lab5-p2-dns.jpg)
![lab5-p2-tls](shots/lab5-p2-tls.jpg)
![lab5-p2-capsules](shots/lab5-p2-capsules.jpg)
![lab5-instances-no-db](shots/lab5-instances-no-db.jpg)

Одной пачкой DELETE A и CREATE CNAME с TTL 60: сразу после смены `dig` ещё вернул старый адрес, через минуту CNAME на endpoint RDS. `/health` отвечает `ok`, TLS 1.3 к базе. Новая капсула №4 создана в приложении и лежит в RDS. `db-server` остановил (приложение работает), затем terminate.

ответ: `DB_HOST` не менялся, потому что приложение ходит на имя `db.timecapsule.internal`, а я поменял только то, что за именем стоит (A на `db-server` на CNAME на endpoint). К AWS перешли ОС и минорные патчи PostgreSQL, ежедневные копии и журнал для восстановления на момент времени, диск и железо, замена экземпляра при поломке железа. За мной остались схема и запросы, пользователи и пароли, сеть (SG, подсети), выбор срока копий, мониторинг, мажорные обновления, остановка и расходы.

### Задание 11. Обслуживание

![lab5-reboot-health](shots/lab5-reboot-health.jpg)
![lab5-rds-events](shots/lab5-rds-events.jpg)
Reboot (форма без failover, Single-AZ): `/health` отвечал 500 около 11 секунд (06:52:27-06:52:37 UTC), потом снова 200. Stop/Start: остановка 4-5 минут, старт около 5, endpoint не изменился. При остановленной базе `/health` даёт 500 (приложение без базы не работает). Повторный `StopDBInstance` на остановленной: `InvalidDBInstanceState`.

### Задание 12. CloudTrail

![lab5-cloudtrail-stop](shots/lab5-cloudtrail-stop.jpg)

Событие `StopDBInstance` в 08:38:28 UTC+02 выполнено сессией роли `timecapsule-dev-scheduler-role` (`userAgent` EventBridgeScheduler), `requestParameters` с одним `timecapsule-dev-rds`. Временные ключи на рисунке закрыты.

### Схема и ADR

![Схема](arch.png)

Схема ЛР4 плюс RDS в приватной подсети (вторая подсеть в группе пустая), Scheduler с ролью и CNAME в зоне `timecapsule.internal`.

Решение записано в [ADR-0004](../adr/0004-database-hosting.md): PostgreSQL на EC2, RDS Single-AZ, Multi-AZ и Aurora, выбран Single-AZ.

---

## Грабли

- Free plan: копии максимум 1 день (ошибка про 7 дней) и не больше двух экземпляров RDS, базу приложения создавал после удаления учебных.
- Реплика: форма падала на Enhanced monitoring (нет прав создать роль), помогло его снять; создавать реплику можно только когда основная Available.
- Список SG в форме RDS показывает удалённые `lab5-*` ещё какое-то время.
- Остановка RDS заняла 4-5 минут, старт около 5; запущенная после остановки база сама Available только после `backing-up`.
- Поле `Day of the week` в cron Scheduler получает `??`, надо перепечатать.
- PostgreSQL 16.12 в RDS против 16.16 на `db-server`, дамп всё равно загрузился.

## Q&A (устные вопросы)

1. Запрос из браузера идёт на Elastic IP `app`: Internet Gateway, `timecapsule-dev-web-sg` пускает 80 из интернета, nginx, PHP-FPM. PHP разрешает `db.timecapsule.internal` через резолвер VPC: приватная зона отдаёт CNAME на endpoint, а он резолвится в приватный адрес в `private-a`. Пакет на 5432 идёт по маршруту `local`, NACL подсетей его пропускает, `timecapsule-dev-rds-sg` пускает только источник `timecapsule-dev-web-sg`; дальше TLS и вход под `timecapsule` в базу `timecapsule`.
2. Репликация повторяет текущие изменения на другой экземпляр (в том числе ошибочные), поэтому помогает при отказе сервера и для чтения, но не откатывает данные. Резервная копия (снимок плюс журнал) хранит прошлые состояния, из неё можно вернуться на момент до ошибки, но это новая база и минуты ожидания. Нужны обе вещи, одна не заменяет другую.
3. Сейчас отказ `1a` переживается вручную: `Restore to point in time` в `eu-central-1b` (подсеть там есть в группе), CNAME `db` на новый endpoint и приложение из `public-b`; десятки минут простоя и до 5 минут потерянных записей, почти бесплатно. Автоматически это даёт Multi-AZ: резерв в `1b`, переключение за минуту-две без потерь, но экземпляр и диск стоят вдвое больше (около 0,038 USD/ч и 5,2 USD/мес).
4. Ночное расписание: каждый день в 23:00 по Кишинёву `StopDBInstance` от роли с правом только на эту базу. Если AWS запустит базу через 7 дней остановки, она проработает не дольше чем до ближайших 23:00. Дополнительно останавливаю базу руками после занятия, а бюджет `ZeroSpend` напишет, если что-то пойдёт не так.

## Итог

`timecapsule-dev-rds` остановлена (Stopped), расписание Enabled, `app` и `bastion` остановлены, `db-server` и `lab5-tmp-web` удалены. Платят диск RDS, Elastic IP `app`, зона Route 53 и диски EBS.

## Ссылки

- [Amazon RDS: Working with DB instance read replicas](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_ReadRepl.html)
- [Restoring a DB instance to a specified time](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PIT.html)
- [Stopping an Amazon RDS DB instance temporarily](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_StopInstance.html)
- [EventBridge Scheduler: universal targets](https://docs.aws.amazon.com/scheduler/latest/UserGuide/managing-targets-universal.html)
