\set ON_ERROR_STOP on

-- ============================================================
-- Automated project checks. Stops with an exception on failure.
-- ============================================================

DO $$
DECLARE
    n BIGINT;
    completed_sum NUMERIC(18,2);
    mart_sum NUMERIC(18,2);
    budget_diff NUMERIC(18,4);
BEGIN
    SELECT COUNT(*) INTO n FROM stg.customers;
    IF n < 100 THEN RAISE EXCEPTION 'FAIL: stg.customers has % rows', n; END IF;

    SELECT COUNT(*) INTO n FROM stg.channels;
    IF n < 4 THEN RAISE EXCEPTION 'FAIL: stg.channels has % rows', n; END IF;

    SELECT COUNT(*) INTO n FROM stg.campaigns;
    IF n < 10 THEN RAISE EXCEPTION 'FAIL: stg.campaigns has % rows', n; END IF;

    SELECT COUNT(*) INTO n FROM stg.orders;
    IF n < 600 THEN RAISE EXCEPTION 'FAIL: stg.orders has % rows', n; END IF;

    SELECT COUNT(*) INTO n FROM stg.order_items;
    IF n < 2000 THEN RAISE EXCEPTION 'FAIL: stg.order_items has % rows', n; END IF;

    SELECT COUNT(*) INTO n FROM dds.dim_customers;
    IF n = 0 THEN RAISE EXCEPTION 'FAIL: dds.dim_customers is empty'; END IF;

    SELECT COUNT(*) INTO n FROM dds.dim_channels;
    IF n = 0 THEN RAISE EXCEPTION 'FAIL: dds.dim_channels is empty'; END IF;

    SELECT COUNT(*) INTO n FROM dds.dim_campaigns;
    IF n = 0 THEN RAISE EXCEPTION 'FAIL: dds.dim_campaigns is empty'; END IF;

    SELECT COUNT(*) INTO n FROM dds.fact_orders;
    IF n = 0 THEN RAISE EXCEPTION 'FAIL: dds.fact_orders is empty'; END IF;

    SELECT COUNT(*) INTO n FROM dds.fact_order_items;
    IF n = 0 THEN RAISE EXCEPTION 'FAIL: dds.fact_order_items is empty'; END IF;

    SELECT COUNT(*) INTO n FROM cdm.dm_sales_performance;
    IF n = 0 THEN RAISE EXCEPTION 'FAIL: cdm.dm_sales_performance is empty'; END IF;

    SELECT COALESCE(SUM(order_amount), 0)
      INTO completed_sum
    FROM dds.fact_orders
    WHERE order_status = 'completed';

    SELECT COALESCE(SUM(revenue), 0)
      INTO mart_sum
    FROM cdm.dm_sales_performance;

    IF ABS(completed_sum - mart_sum) > 0.01 THEN
        RAISE EXCEPTION 'FAIL: completed revenue differs: DDS %, CDM %',
            completed_sum, mart_sum;
    END IF;

    SELECT COALESCE(MAX(ABS(x.allocated_spend - x.campaign_budget)), 0)
      INTO budget_diff
    FROM (
        SELECT campaign_id,
               SUM(spend) AS allocated_spend,
               MAX(campaign_budget) AS campaign_budget
        FROM cdm.dm_sales_performance
        GROUP BY campaign_id
    ) x;

    IF budget_diff > 0.05 THEN
        RAISE EXCEPTION 'FAIL: allocated campaign spend differs from budget by %',
            budget_diff;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'dds'
          AND table_name IN (
              'dim_customers', 'dim_channels', 'dim_campaigns',
              'fact_orders', 'fact_order_items'
          )
        GROUP BY table_name
        HAVING SUM(CASE WHEN column_name = 'load_dt' THEN 1 ELSE 0 END) = 0
            OR SUM(CASE WHEN column_name = 'load_src' THEN 1 ELSE 0 END) = 0
    ) THEN
        RAISE EXCEPTION 'FAIL: a DDS table is missing load_dt or load_src';
    END IF;

    RAISE NOTICE 'PASS: all automated project checks completed successfully';
END $$;

-- Human-readable evidence for the submission.
SELECT 'STG customers' AS check_name, COUNT(*) AS actual, 100 AS minimum
FROM stg.customers
UNION ALL SELECT 'STG channels', COUNT(*), 4 FROM stg.channels
UNION ALL SELECT 'STG campaigns', COUNT(*), 10 FROM stg.campaigns
UNION ALL SELECT 'STG orders', COUNT(*), 600 FROM stg.orders
UNION ALL SELECT 'STG order_items', COUNT(*), 2000 FROM stg.order_items;

SELECT order_status, COUNT(*) AS orders, SUM(order_amount)::NUMERIC(18,2) AS amount
FROM dds.fact_orders
GROUP BY order_status
ORDER BY order_status;

SELECT
    SUM(orders_count) AS completed_orders_in_cdm,
    SUM(new_customers) AS new_customers,
    SUM(spend)::NUMERIC(18,2) AS total_spend,
    SUM(revenue)::NUMERIC(18,2) AS total_revenue,
    CASE WHEN SUM(spend) > 0
         THEN ((SUM(revenue) - SUM(spend)) / SUM(spend))::NUMERIC(18,4)
         ELSE NULL
    END AS overall_roi
FROM cdm.dm_sales_performance;
