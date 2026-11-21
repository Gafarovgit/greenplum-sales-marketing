# Greenplum: Sales & Marketing DWH

Проект для Greenplum Database 7.x. Скрипты рассчитаны на запуск из `psql`
в базе `sales_marketing`.

## Состав

1. `01_build_stg_dds.sql` — пересоздаёт схемы `stg`, `dds`, `cdm`, генерирует
   исходные данные и загружает измерения и факты DDS.
2. `02_build_cdm.sql` — создаёт дневную витрину `cdm.dm_sales_performance`.
3. `03_business_reports.sql` — четыре бизнес-отчёта, EXPLAIN и EXPLAIN ANALYZE.
4. `04_validation.sql` — базовые автоматические проверки с остановкой при ошибке.
5. `05_extended_audit.sql` — расширенный аудит ключей, связей, сумм позиций и витрины.
6. `architecture_report.md` — отчёт по архитектуре и бизнес-правилам.

## Запуск из macOS Terminal

Выйди из интерактивного psql, если ты сейчас в нём:

```sql
\q
```

На Mac выполни команды из каталога, куда распакован архив:

```bash
docker exec -i greenplum-container su - gpadmin -c "/usr/local/gpdb/bin/psql -d sales_marketing -v ON_ERROR_STOP=1" < 01_build_stg_dds.sql
docker exec -i greenplum-container su - gpadmin -c "/usr/local/gpdb/bin/psql -d sales_marketing -v ON_ERROR_STOP=1" < 02_build_cdm.sql
docker exec -i greenplum-container su - gpadmin -c "/usr/local/gpdb/bin/psql -d sales_marketing -v ON_ERROR_STOP=1" < 03_business_reports.sql
docker exec -i greenplum-container su - gpadmin -c "/usr/local/gpdb/bin/psql -d sales_marketing -v ON_ERROR_STOP=1" < 04_validation.sql
docker exec -i greenplum-container su - gpadmin -c "/usr/local/gpdb/bin/psql -d sales_marketing -v ON_ERROR_STOP=1" < 05_extended_audit.sql
```

Запускать именно в указанном порядке. Первый скрипт удаляет и пересоздаёт
схемы проекта — это намеренно обеспечивает воспроизводимую сборку с нуля.

## Архитектура

- **STG** — пять таблиц, близких к источникам.
- **DDS** — три измерения и два факта; во всех DDS-таблицах есть `load_dt`
  и `load_src`.
- **CDM** — дневная витрина по кампании и каналу.

## Объём тестовых данных

Генерируются 250 клиентов, 4 канала, 12 кампаний, 1 200 заказов и от 2 400
до 4 800 позиций заказа. Данные генерируются SQL средствами `generate_series`,
`random()` и `CASE`.

## Бизнес-правила витрины

- В выручку и количество заказов попадают только `completed`.
- Отменённые и возвращённые заказы остаются в DDS, но не участвуют в продажах.
- Общий бюджет кампании равномерно распределяется на каждый календарный день
  её активности. Поэтому сумма дневного `spend` за кампанию равна её бюджету.
- `revenue` — сумма `order_amount` завершённых заказов.
- `roi = (revenue - spend) / spend`.
- `new_customers` — клиенты, для которых завершённый заказ в этот день является
  первой завершённой покупкой во всём наборе данных.
- `avg_order_amount` — выручка дня / количество завершённых заказов дня;
  при отсутствии заказов равно нулю.

## MPP-решения

- `fact_orders` и `fact_order_items` распределены по `order_id`, чтобы
  минимизировать перераспределение данных при соединении заголовков заказов
  с позициями.
- Измерения распределены по собственным идентификаторам.
- CDM распределена по `campaign_id`, так как основной аналитический разрез —
  эффективность кампаний.
- Факты и витрина разбиты на месячные диапазоны по датам. Это позволяет
  отсекать нерелевантные партиции при фильтрах по периоду.
- После загрузки выполняется `ANALYZE`; в отчётах есть `EXPLAIN` и
  `EXPLAIN ANALYZE`.

## Важное замечание

Это воспроизводимый учебный набор данных, а не реальные коммерческие данные.
Ключи и связи контролируются логикой генерации и ETL; физические ограничения
уникальности в распределённой MPP-модели не следует считать заменой проверок
качества данных.
