\set ON_ERROR_STOP on

-- ============================================================
-- Greenplum Sales & Marketing DWH
-- 01. Rebuild STG and DDS from scratch
-- Target: Greenplum Database 7.x / PostgreSQL-compatible SQL
-- WARNING: drops project schemas if they already exist.
-- ============================================================

DROP SCHEMA IF EXISTS cdm CASCADE;
DROP SCHEMA IF EXISTS dds CASCADE;
DROP SCHEMA IF EXISTS stg CASCADE;

CREATE SCHEMA stg;
CREATE SCHEMA dds;
CREATE SCHEMA cdm;

-- -------------------------
-- STG: source-like layer
-- -------------------------
CREATE TABLE stg.customers (
    customer_id       INTEGER NOT NULL,
    customer_name     VARCHAR(120) NOT NULL,
    signup_dt         DATE NOT NULL,
    region            VARCHAR(50) NOT NULL,
    customer_segment  VARCHAR(30) NOT NULL
)
DISTRIBUTED BY (customer_id);

CREATE TABLE stg.channels (
    channel_id    INTEGER NOT NULL,
    channel_name  VARCHAR(80) NOT NULL,
    channel_type  VARCHAR(40) NOT NULL
)
DISTRIBUTED BY (channel_id);

CREATE TABLE stg.campaigns (
    campaign_id    INTEGER NOT NULL,
    campaign_name  VARCHAR(120) NOT NULL,
    channel_id     INTEGER NOT NULL,
    start_dt       DATE NOT NULL,
    end_dt         DATE NOT NULL,
    budget         NUMERIC(14,2) NOT NULL
)
DISTRIBUTED BY (campaign_id);

CREATE TABLE stg.orders (
    order_id       BIGINT NOT NULL,
    order_dt       DATE NOT NULL,
    customer_id    INTEGER NOT NULL,
    campaign_id    INTEGER NOT NULL,
    order_amount   NUMERIC(18,2) NOT NULL DEFAULT 0,
    order_status   VARCHAR(20) NOT NULL
)
DISTRIBUTED BY (order_id);

CREATE TABLE stg.order_items (
    order_item_id  BIGINT NOT NULL,
    order_id       BIGINT NOT NULL,
    product_id     INTEGER NOT NULL,
    product_name   VARCHAR(100) NOT NULL,
    quantity       INTEGER NOT NULL,
    price          NUMERIC(12,2) NOT NULL
)
DISTRIBUTED BY (order_id);

-- Fixed seed makes the generated dataset repeatable for review.
SELECT setseed(0.4242);

INSERT INTO stg.customers
SELECT
    g,
    'Customer ' || LPAD(g::text, 4, '0'),
    DATE '2023-01-01' + (random() * 1094)::INTEGER,
    CASE (g % 8)
        WHEN 0 THEN 'Moscow'
        WHEN 1 THEN 'Saint Petersburg'
        WHEN 2 THEN 'Central'
        WHEN 3 THEN 'North-West'
        WHEN 4 THEN 'South'
        WHEN 5 THEN 'Volga'
        WHEN 6 THEN 'Ural'
        ELSE 'Siberia'
    END,
    CASE (g % 4)
        WHEN 0 THEN 'new'
        WHEN 1 THEN 'regular'
        WHEN 2 THEN 'premium'
        ELSE 'corporate'
    END
FROM generate_series(1, 250) AS g;

INSERT INTO stg.channels VALUES
    (1, 'Search Ads', 'Paid Search'),
    (2, 'Social Media', 'Paid Social'),
    (3, 'Email', 'Owned'),
    (4, 'Affiliate', 'Partner');

INSERT INTO stg.campaigns
SELECT
    g,
    'Campaign ' || LPAD(g::text, 3, '0'),
    ((g - 1) % 4) + 1,
    DATE '2024-01-01' + ((g - 1) * 45),
    DATE '2024-01-01' + ((g - 1) * 45) + 119,
    (10000 + random() * 40000)::NUMERIC(14,2)
FROM generate_series(1, 12) AS g;

-- Generate 1,200 orders over active campaign periods.
INSERT INTO stg.orders
    (order_id, order_dt, customer_id, campaign_id, order_amount, order_status)
SELECT
    g,
    c.start_dt + (random() * (c.end_dt - c.start_dt))::INTEGER,
    1 + (random() * 249)::INTEGER,
    c.campaign_id,
    0,
    CASE
        WHEN random() < 0.76 THEN 'completed'
        WHEN random() < 0.88 THEN 'cancelled'
        ELSE 'returned'
    END
FROM generate_series(1, 1200) AS g
JOIN stg.campaigns c
  ON c.campaign_id = ((g - 1) % 12) + 1;

-- 2-4 line items per order.
INSERT INTO stg.order_items
    (order_item_id, order_id, product_id, product_name, quantity, price)
SELECT
    ROW_NUMBER() OVER (ORDER BY o.order_id, item_no),
    o.order_id,
    1 + (random() * 49)::INTEGER,
    'Product ' || LPAD((1 + (random() * 49)::INTEGER)::TEXT, 3, '0'),
    1 + (random() * 4)::INTEGER,
    (100 + random() * 4900)::NUMERIC(12,2)
FROM stg.orders o
CROSS JOIN LATERAL generate_series(1, 2 + (o.order_id % 3)::INTEGER) AS item_no;

-- Make order header amounts consistent with the sum of its lines.
UPDATE stg.orders o
SET order_amount = x.line_total
FROM (
    SELECT order_id, SUM(quantity * price)::NUMERIC(18,2) AS line_total
    FROM stg.order_items
    GROUP BY order_id
) x
WHERE x.order_id = o.order_id;

-- -------------------------
-- DDS: dimensions
-- -------------------------
CREATE TABLE dds.dim_customers (
    customer_id       INTEGER NOT NULL,
    customer_name     VARCHAR(120) NOT NULL,
    signup_dt         DATE NOT NULL,
    region            VARCHAR(50) NOT NULL,
    customer_segment  VARCHAR(30) NOT NULL,
    load_dt           TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    load_src          VARCHAR(50) NOT NULL
)
DISTRIBUTED BY (customer_id);

CREATE TABLE dds.dim_channels (
    channel_id    INTEGER NOT NULL,
    channel_name  VARCHAR(80) NOT NULL,
    channel_type  VARCHAR(40) NOT NULL,
    load_dt       TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    load_src      VARCHAR(50) NOT NULL
)
DISTRIBUTED BY (channel_id);

CREATE TABLE dds.dim_campaigns (
    campaign_id    INTEGER NOT NULL,
    campaign_name  VARCHAR(120) NOT NULL,
    channel_id     INTEGER NOT NULL,
    start_dt       DATE NOT NULL,
    end_dt         DATE NOT NULL,
    budget         NUMERIC(14,2) NOT NULL,
    load_dt        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    load_src       VARCHAR(50) NOT NULL
)
DISTRIBUTED BY (campaign_id);

INSERT INTO dds.dim_customers
SELECT customer_id, customer_name, signup_dt, region, customer_segment,
       CURRENT_TIMESTAMP, 'stg.customers'
FROM stg.customers;

INSERT INTO dds.dim_channels
SELECT channel_id, channel_name, channel_type,
       CURRENT_TIMESTAMP, 'stg.channels'
FROM stg.channels;

INSERT INTO dds.dim_campaigns
SELECT campaign_id, campaign_name, channel_id, start_dt, end_dt, budget,
       CURRENT_TIMESTAMP, 'stg.campaigns'
FROM stg.campaigns;

-- -------------------------
-- DDS: facts, monthly range partitioned by business date.
-- Both fact tables use order_id distribution to colocate line
-- items with their order header for the most common fact join.
-- -------------------------
CREATE TABLE dds.fact_orders (
    order_id       BIGINT NOT NULL,
    order_dt       DATE NOT NULL,
    customer_id    INTEGER NOT NULL,
    campaign_id    INTEGER NOT NULL,
    order_amount   NUMERIC(18,2) NOT NULL,
    order_status   VARCHAR(20) NOT NULL,
    load_dt        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    load_src       VARCHAR(50) NOT NULL
)
DISTRIBUTED BY (order_id)
PARTITION BY RANGE (order_dt)
(
    START (DATE '2024-01-01') INCLUSIVE
    END (DATE '2026-01-01') EXCLUSIVE
    EVERY (INTERVAL '1 month'),
    DEFAULT PARTITION other_dates
);

CREATE TABLE dds.fact_order_items (
    order_item_id  BIGINT NOT NULL,
    order_id       BIGINT NOT NULL,
    order_dt       DATE NOT NULL,
    product_id     INTEGER NOT NULL,
    product_name   VARCHAR(100) NOT NULL,
    quantity       INTEGER NOT NULL,
    price          NUMERIC(12,2) NOT NULL,
    line_amount    NUMERIC(18,2) NOT NULL,
    load_dt        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    load_src       VARCHAR(50) NOT NULL
)
DISTRIBUTED BY (order_id)
PARTITION BY RANGE (order_dt)
(
    START (DATE '2024-01-01') INCLUSIVE
    END (DATE '2026-01-01') EXCLUSIVE
    EVERY (INTERVAL '1 month'),
    DEFAULT PARTITION other_dates
);

INSERT INTO dds.fact_orders
SELECT order_id, order_dt, customer_id, campaign_id, order_amount, order_status,
       CURRENT_TIMESTAMP, 'stg.orders'
FROM stg.orders;

INSERT INTO dds.fact_order_items
SELECT i.order_item_id, i.order_id, o.order_dt, i.product_id, i.product_name,
       i.quantity, i.price, (i.quantity * i.price)::NUMERIC(18,2),
       CURRENT_TIMESTAMP, 'stg.order_items'
FROM stg.order_items i
JOIN stg.orders o ON o.order_id = i.order_id;

ANALYZE stg.customers;
ANALYZE stg.channels;
ANALYZE stg.campaigns;
ANALYZE stg.orders;
ANALYZE stg.order_items;
ANALYZE dds.dim_customers;
ANALYZE dds.dim_channels;
ANALYZE dds.dim_campaigns;
ANALYZE dds.fact_orders;
ANALYZE dds.fact_order_items;

-- Build summary of loaded volumes.
SELECT 'stg.customers' AS table_name, COUNT(*) AS row_count FROM stg.customers
UNION ALL SELECT 'stg.channels', COUNT(*) FROM stg.channels
UNION ALL SELECT 'stg.campaigns', COUNT(*) FROM stg.campaigns
UNION ALL SELECT 'stg.orders', COUNT(*) FROM stg.orders
UNION ALL SELECT 'stg.order_items', COUNT(*) FROM stg.order_items
UNION ALL SELECT 'dds.dim_customers', COUNT(*) FROM dds.dim_customers
UNION ALL SELECT 'dds.dim_channels', COUNT(*) FROM dds.dim_channels
UNION ALL SELECT 'dds.dim_campaigns', COUNT(*) FROM dds.dim_campaigns
UNION ALL SELECT 'dds.fact_orders', COUNT(*) FROM dds.fact_orders
UNION ALL SELECT 'dds.fact_order_items', COUNT(*) FROM dds.fact_order_items
ORDER BY table_name;
