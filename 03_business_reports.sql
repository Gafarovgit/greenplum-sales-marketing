\set ON_ERROR_STOP on

-- ============================================================
-- Four required business reports. All are sourced from CDM.
-- ============================================================

-- 1. Top campaigns by ROI (weighted overall ROI, not average of daily ROI).
SELECT
    campaign_id,
    campaign_name,
    channel_name,
    SUM(revenue)::NUMERIC(18,2) AS revenue,
    SUM(spend)::NUMERIC(18,2) AS spend,
    CASE WHEN SUM(spend) > 0
         THEN ((SUM(revenue) - SUM(spend)) / SUM(spend))::NUMERIC(18,4)
         ELSE NULL
    END AS roi
FROM cdm.dm_sales_performance
GROUP BY campaign_id, campaign_name, channel_name
ORDER BY roi DESC NULLS LAST
LIMIT 10;

-- 2. Actual allocated spend versus campaign budget.
SELECT
    campaign_id,
    campaign_name,
    channel_name,
    MAX(campaign_budget)::NUMERIC(14,2) AS campaign_budget,
    SUM(spend)::NUMERIC(18,2) AS actual_allocated_spend,
    (SUM(spend) - MAX(campaign_budget))::NUMERIC(18,2) AS budget_variance
FROM cdm.dm_sales_performance
GROUP BY campaign_id, campaign_name, channel_name
ORDER BY campaign_id;

-- 3. New customers by campaign.
SELECT
    campaign_id,
    campaign_name,
    channel_name,
    SUM(new_customers) AS new_customers,
    SUM(orders_count) AS completed_orders,
    SUM(revenue)::NUMERIC(18,2) AS revenue
FROM cdm.dm_sales_performance
GROUP BY campaign_id, campaign_name, channel_name
ORDER BY new_customers DESC, revenue DESC;

-- 4. Advertising channel performance.
SELECT
    channel_id,
    channel_name,
    COUNT(DISTINCT campaign_id) AS campaigns_count,
    SUM(orders_count) AS completed_orders,
    SUM(customers_count) AS customer_campaign_days,
    SUM(new_customers) AS new_customers,
    SUM(spend)::NUMERIC(18,2) AS spend,
    SUM(revenue)::NUMERIC(18,2) AS revenue,
    CASE WHEN SUM(spend) > 0
         THEN ((SUM(revenue) - SUM(spend)) / SUM(spend))::NUMERIC(18,4)
         ELSE NULL
    END AS roi
FROM cdm.dm_sales_performance
GROUP BY channel_id, channel_name
ORDER BY roi DESC NULLS LAST;

-- Optimization evidence: inspect a campaign/date-filtered query.
EXPLAIN
SELECT report_dt, campaign_id, SUM(revenue)
FROM cdm.dm_sales_performance
WHERE report_dt >= DATE '2024-06-01'
  AND report_dt <  DATE '2024-07-01'
GROUP BY report_dt, campaign_id;

EXPLAIN ANALYZE
SELECT report_dt, campaign_id, SUM(revenue)
FROM cdm.dm_sales_performance
WHERE report_dt >= DATE '2024-06-01'
  AND report_dt <  DATE '2024-07-01'
GROUP BY report_dt, campaign_id;
