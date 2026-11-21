\set ON_ERROR_STOP on

-- ============================================================
-- 02. CDM sales performance mart
-- Grain: one row per campaign, channel and calendar day.
-- Only completed orders contribute to revenue and order metrics.
-- Spend is allocated evenly across all calendar days of a campaign.
-- A row is retained for every active campaign day, including
-- days with no completed orders, so spend is not understated.
-- New customers = customers whose first completed purchase
-- across the dataset occurred on this campaign/day.
-- ROI = (revenue - spend) / spend.
-- ============================================================

DROP TABLE IF EXISTS cdm.dm_sales_performance;

CREATE TABLE cdm.dm_sales_performance (
    report_dt          DATE NOT NULL,
    campaign_id        INTEGER NOT NULL,
    campaign_name      VARCHAR(120) NOT NULL,
    channel_id         INTEGER NOT NULL,
    channel_name       VARCHAR(80) NOT NULL,
    orders_count       BIGINT NOT NULL,
    customers_count    BIGINT NOT NULL,
    order_amount       NUMERIC(18,2) NOT NULL,
    avg_order_amount   NUMERIC(18,2) NOT NULL,
    new_customers      BIGINT NOT NULL,
    campaign_budget    NUMERIC(14,2) NOT NULL,
    spend              NUMERIC(18,6) NOT NULL,
    revenue            NUMERIC(18,2) NOT NULL,
    roi                NUMERIC(18,4)
)
DISTRIBUTED BY (campaign_id)
PARTITION BY RANGE (report_dt)
(
    START (DATE '2024-01-01') INCLUSIVE
    END (DATE '2026-01-01') EXCLUSIVE
    EVERY (INTERVAL '1 month'),
    DEFAULT PARTITION other_dates
);

WITH campaign_calendar AS (
    SELECT
        c.campaign_id,
        c.campaign_name,
        c.channel_id,
        ch.channel_name,
        c.start_dt,
        c.end_dt,
        c.budget,
        (c.end_dt - c.start_dt + 1) AS campaign_days,
        gs::DATE AS report_dt
    FROM dds.dim_campaigns c
    JOIN dds.dim_channels ch ON ch.channel_id = c.channel_id
    CROSS JOIN LATERAL generate_series(
        c.start_dt::TIMESTAMP,
        c.end_dt::TIMESTAMP,
        INTERVAL '1 day'
    ) AS gs
),
first_completed_purchase AS (
    -- Attribute each customer to exactly one first completed order.
    -- order_id breaks ties when a customer has multiple orders on one day.
    SELECT customer_id, order_dt AS first_order_dt, campaign_id AS first_campaign_id
    FROM (
        SELECT
            customer_id,
            order_dt,
            campaign_id,
            ROW_NUMBER() OVER (
                PARTITION BY customer_id
                ORDER BY order_dt, order_id
            ) AS purchase_rank
        FROM dds.fact_orders
        WHERE order_status = 'completed'
    ) ranked
    WHERE purchase_rank = 1
),
daily_sales AS (
    SELECT
        f.order_dt AS report_dt,
        f.campaign_id,
        COUNT(DISTINCT f.order_id) AS orders_count,
        COUNT(DISTINCT f.customer_id) AS customers_count,
        SUM(f.order_amount)::NUMERIC(18,2) AS revenue,
        COUNT(DISTINCT CASE
            WHEN fp.first_order_dt = f.order_dt
             AND fp.first_campaign_id = f.campaign_id
            THEN f.customer_id
        END) AS new_customers
    FROM dds.fact_orders f
    LEFT JOIN first_completed_purchase fp
      ON fp.customer_id = f.customer_id
    WHERE f.order_status = 'completed'
    GROUP BY f.order_dt, f.campaign_id
)
INSERT INTO cdm.dm_sales_performance
SELECT
    cal.report_dt,
    cal.campaign_id,
    cal.campaign_name,
    cal.channel_id,
    cal.channel_name,
    COALESCE(ds.orders_count, 0),
    COALESCE(ds.customers_count, 0),
    COALESCE(ds.revenue, 0)::NUMERIC(18,2),
    CASE WHEN COALESCE(ds.orders_count, 0) > 0
         THEN (ds.revenue / ds.orders_count)::NUMERIC(18,2)
         ELSE 0::NUMERIC(18,2)
    END,
    COALESCE(ds.new_customers, 0),
    cal.budget,
    (cal.budget / cal.campaign_days)::NUMERIC(18,6),
    COALESCE(ds.revenue, 0)::NUMERIC(18,2),
    CASE
        WHEN cal.budget > 0 AND cal.campaign_days > 0
        THEN (
            (COALESCE(ds.revenue, 0) - (cal.budget / cal.campaign_days))
            / (cal.budget / cal.campaign_days)
        )::NUMERIC(18,4)
        ELSE NULL
    END
FROM campaign_calendar cal
LEFT JOIN daily_sales ds
  ON ds.report_dt = cal.report_dt
 AND ds.campaign_id = cal.campaign_id;

ANALYZE cdm.dm_sales_performance;

SELECT
    COUNT(*) AS mart_rows,
    SUM(orders_count) AS completed_orders,
    SUM(customers_count) AS daily_customer_count_sum,
    SUM(revenue) AS total_revenue,
    SUM(spend) AS allocated_spend,
    SUM(new_customers) AS first_time_buyers
FROM cdm.dm_sales_performance;
