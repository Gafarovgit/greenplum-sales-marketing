\set ON_ERROR_STOP on

-- Extended independent audit: keys, references, ETL consistency and CDM grain.
DO $$
DECLARE
    n BIGINT;
    v1 NUMERIC(18,2);
    v2 NUMERIC(18,2);
BEGIN
    -- Natural-key uniqueness in STG.
    IF EXISTS (SELECT customer_id FROM stg.customers GROUP BY customer_id HAVING COUNT(*) > 1)
       THEN RAISE EXCEPTION 'FAIL: duplicate customer_id in STG'; END IF;
    IF EXISTS (SELECT channel_id FROM stg.channels GROUP BY channel_id HAVING COUNT(*) > 1)
       THEN RAISE EXCEPTION 'FAIL: duplicate channel_id in STG'; END IF;
    IF EXISTS (SELECT campaign_id FROM stg.campaigns GROUP BY campaign_id HAVING COUNT(*) > 1)
       THEN RAISE EXCEPTION 'FAIL: duplicate campaign_id in STG'; END IF;
    IF EXISTS (SELECT order_id FROM stg.orders GROUP BY order_id HAVING COUNT(*) > 1)
       THEN RAISE EXCEPTION 'FAIL: duplicate order_id in STG'; END IF;
    IF EXISTS (SELECT order_item_id FROM stg.order_items GROUP BY order_item_id HAVING COUNT(*) > 1)
       THEN RAISE EXCEPTION 'FAIL: duplicate order_item_id in STG'; END IF;

    -- Referential integrity of generated source data.
    IF EXISTS (SELECT 1 FROM stg.campaigns c LEFT JOIN stg.channels ch USING (channel_id) WHERE ch.channel_id IS NULL)
       THEN RAISE EXCEPTION 'FAIL: campaign references missing channel'; END IF;
    IF EXISTS (SELECT 1 FROM stg.orders o LEFT JOIN stg.customers c USING (customer_id) WHERE c.customer_id IS NULL)
       THEN RAISE EXCEPTION 'FAIL: order references missing customer'; END IF;
    IF EXISTS (SELECT 1 FROM stg.orders o LEFT JOIN stg.campaigns c USING (campaign_id) WHERE c.campaign_id IS NULL)
       THEN RAISE EXCEPTION 'FAIL: order references missing campaign'; END IF;
    IF EXISTS (SELECT 1 FROM stg.order_items i LEFT JOIN stg.orders o USING (order_id) WHERE o.order_id IS NULL)
       THEN RAISE EXCEPTION 'FAIL: order item references missing order'; END IF;

    -- Header amount must equal sum of item lines.
    SELECT COUNT(*) INTO n
    FROM (
        SELECT o.order_id
        FROM stg.orders o
        JOIN (
            SELECT order_id, SUM(quantity * price)::NUMERIC(18,2) AS item_total
            FROM stg.order_items
            GROUP BY order_id
        ) i USING (order_id)
        WHERE o.order_amount <> i.item_total
    ) mismatch;
    IF n > 0 THEN RAISE EXCEPTION 'FAIL: % orders have header/item amount mismatch', n; END IF;

    -- DDS must preserve STG row counts.
    SELECT COUNT(*) INTO n FROM stg.orders;
    IF n <> (SELECT COUNT(*) FROM dds.fact_orders)
       THEN RAISE EXCEPTION 'FAIL: STG/DDS orders row counts differ'; END IF;
    SELECT COUNT(*) INTO n FROM stg.order_items;
    IF n <> (SELECT COUNT(*) FROM dds.fact_order_items)
       THEN RAISE EXCEPTION 'FAIL: STG/DDS order item row counts differ'; END IF;

    -- CDM counts must contain completed orders only.
    SELECT COUNT(*) INTO n FROM dds.fact_orders WHERE order_status = 'completed';
    IF n <> (SELECT COALESCE(SUM(orders_count), 0) FROM cdm.dm_sales_performance)
       THEN RAISE EXCEPTION 'FAIL: CDM order count does not equal completed DDS orders'; END IF;

    SELECT COALESCE(SUM(order_amount), 0) INTO v1
    FROM dds.fact_orders WHERE order_status = 'completed';
    SELECT COALESCE(SUM(revenue), 0) INTO v2
    FROM cdm.dm_sales_performance;
    IF ABS(v1 - v2) > 0.01
       THEN RAISE EXCEPTION 'FAIL: completed revenue mismatch: DDS %, CDM %', v1, v2; END IF;

    -- Each campaign has one daily row for every active date.
    IF EXISTS (
        SELECT 1
        FROM dds.dim_campaigns c
        LEFT JOIN (
            SELECT campaign_id, COUNT(*) AS day_rows
            FROM cdm.dm_sales_performance
            GROUP BY campaign_id
        ) m USING (campaign_id)
        WHERE COALESCE(m.day_rows, 0) <> (c.end_dt - c.start_dt + 1)
    ) THEN RAISE EXCEPTION 'FAIL: CDM does not contain exactly one row per active campaign day'; END IF;

    -- First-time buyer metric must count each customer once, at first completed purchase.
    SELECT COUNT(*) INTO n
    FROM (
        SELECT customer_id
        FROM (
            SELECT customer_id,
                   ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_dt, order_id) AS rn
            FROM dds.fact_orders
            WHERE order_status = 'completed'
        ) x
        WHERE rn = 1
    ) first_buyers;
    IF n <> (SELECT COALESCE(SUM(new_customers), 0) FROM cdm.dm_sales_performance)
       THEN RAISE EXCEPTION 'FAIL: first-time customer count mismatch'; END IF;

    -- Daily spend allocations should sum back to campaign budgets.
    IF EXISTS (
        SELECT 1
        FROM cdm.dm_sales_performance
        GROUP BY campaign_id
        HAVING ABS(SUM(spend) - MAX(campaign_budget)) > 0.05
    ) THEN RAISE EXCEPTION 'FAIL: daily spend allocation does not reconcile to campaign budget'; END IF;

    RAISE NOTICE 'PASS: extended audit completed successfully';
END $$;

-- Evidence tables for the project report.
SELECT
    'Unique source keys' AS audit_item,
    (SELECT COUNT(*) FROM stg.customers) AS customers,
    (SELECT COUNT(DISTINCT customer_id) FROM stg.customers) AS distinct_customers,
    (SELECT COUNT(*) FROM stg.orders) AS orders,
    (SELECT COUNT(DISTINCT order_id) FROM stg.orders) AS distinct_orders;

SELECT
    c.campaign_id,
    c.campaign_name,
    c.end_dt - c.start_dt + 1 AS expected_days,
    COUNT(m.report_dt) AS actual_days,
    MAX(c.budget)::NUMERIC(14,2) AS campaign_budget,
    SUM(m.spend)::NUMERIC(14,2) AS allocated_spend,
    (SUM(m.spend) - MAX(c.budget))::NUMERIC(14,2) AS reconciliation_delta
FROM dds.dim_campaigns c
JOIN cdm.dm_sales_performance m USING (campaign_id)
GROUP BY c.campaign_id, c.campaign_name, c.start_dt, c.end_dt
ORDER BY c.campaign_id;

SELECT
    COUNT(*) FILTER (WHERE order_status = 'completed') AS completed_orders,
    COUNT(*) FILTER (WHERE order_status = 'cancelled') AS cancelled_orders,
    COUNT(*) FILTER (WHERE order_status = 'returned') AS returned_orders,
    COUNT(*) AS all_orders
FROM dds.fact_orders;
