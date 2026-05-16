-- Migration 014_materialized_views.sql
-- 5 materialized views powering reports & dashboards.
-- All have UNIQUE indexes to enable REFRESH ... CONCURRENTLY.
--
-- Refresh cadence (scheduled by application worker):
--   daily_sales_summary       — every 5 min
--   top_selling_variants      — every 30 min
--   stock_position_summary    — every 10 min
--   customer_aging_summary    — nightly 02:00
--   supplier_aging_summary    — nightly 02:00

-- ============================================================================
-- daily_sales_summary
-- Excludes administratively-reversed sales (canonical business reality)
-- ============================================================================

CREATE MATERIALIZED VIEW daily_sales_summary AS
SELECT
  s.tenant_id,
  s.store_id,
  date_trunc('day', s.completed_at AT TIME ZONE 'Europe/Istanbul')::date AS business_date,
  COUNT(*) AS sale_count,
  SUM(s.total_try) AS total_revenue_try,
  SUM(s.vat_total * COALESCE(NULLIF(s.total_try, 0) / NULLIF(s.total, 0), 1)) AS total_vat_try,
  SUM(s.cart_discount * COALESCE(NULLIF(s.total_try, 0) / NULLIF(s.total, 0), 1)) AS total_discount_try,
  SUM(si.quantity * si.unit_cost_try) AS total_cogs_try,
  SUM(s.total_try) - SUM(si.quantity * si.unit_cost_try) AS gross_profit_try
FROM sales s
JOIN sale_items si ON si.sale_id = s.id
WHERE s.status = 'COMPLETED'
  AND s.administratively_reversed_at IS NULL
GROUP BY s.tenant_id, s.store_id, business_date;

CREATE UNIQUE INDEX idx_dss_unique
  ON daily_sales_summary(tenant_id, store_id, business_date);
CREATE INDEX idx_dss_tenant_date
  ON daily_sales_summary(tenant_id, business_date DESC);


-- ============================================================================
-- top_selling_variants — per-month rankings with revenue, COGS, margin
-- ============================================================================

CREATE MATERIALIZED VIEW top_selling_variants AS
SELECT
  s.tenant_id,
  s.store_id,
  si.variant_id,
  pv.sku AS variant_sku,
  date_trunc('month', s.completed_at AT TIME ZONE 'Europe/Istanbul')::date AS business_month,
  SUM(si.quantity) AS units_sold,
  SUM(si.line_total) AS revenue,
  SUM(si.quantity * si.unit_cost_try) AS cogs_try,
  SUM(si.line_total) - SUM(si.quantity * si.unit_cost_try) AS margin_try
FROM sales s
JOIN sale_items si ON si.sale_id = s.id
JOIN product_variants pv ON pv.id = si.variant_id
WHERE s.status = 'COMPLETED'
  AND s.administratively_reversed_at IS NULL
GROUP BY s.tenant_id, s.store_id, si.variant_id, pv.sku, business_month;

CREATE UNIQUE INDEX idx_tsv_unique
  ON top_selling_variants(tenant_id, store_id, variant_id, business_month);
CREATE INDEX idx_tsv_tenant_month_revenue
  ON top_selling_variants(tenant_id, business_month DESC, revenue DESC);


-- ============================================================================
-- stock_position_summary — current stock by variant with LOW/HIGH/NORMAL flag
-- ============================================================================

CREATE MATERIALIZED VIEW stock_position_summary AS
SELECT
  sb.tenant_id,
  sb.variant_id,
  sb.store_id,
  pv.sku AS variant_sku,
  p.display_name AS product_name,
  sb.quantity,
  sb.average_cost_try,
  sb.total_cost_try,
  rl.min_level,
  rl.max_level,
  rl.reorder_quantity,
  CASE
    WHEN sb.quantity <= 0 THEN 'OUT_OF_STOCK'
    WHEN rl.min_level IS NOT NULL AND sb.quantity < rl.min_level THEN 'LOW'
    WHEN rl.max_level IS NOT NULL AND sb.quantity > rl.max_level THEN 'HIGH'
    ELSE 'NORMAL'
  END AS stock_status,
  sb.last_movement_at,
  sb.last_reconciled_at
FROM stock_balances sb
JOIN product_variants pv ON pv.id = sb.variant_id
JOIN products p ON p.id = pv.product_id
LEFT JOIN reorder_levels rl
  ON rl.variant_id = sb.variant_id AND rl.store_id = sb.store_id
WHERE pv.status != 'ARCHIVED'
  AND p.status != 'ARCHIVED';

CREATE UNIQUE INDEX idx_sps_unique ON stock_position_summary(tenant_id, variant_id, store_id);
CREATE INDEX idx_sps_status ON stock_position_summary(tenant_id, store_id, stock_status);
CREATE INDEX idx_sps_low ON stock_position_summary(tenant_id, store_id)
  WHERE stock_status IN ('LOW','OUT_OF_STOCK');


-- ============================================================================
-- customer_aging_summary — per-customer aging joined with credit_limit
-- ============================================================================

CREATE MATERIALIZED VIEW customer_aging_summary AS
SELECT
  ap.tenant_id,
  ap.party_id,
  p.display_name AS customer_name,
  ap.currency,
  ap.credit_limit,
  ap.credit_used,
  ap.account_status,
  aa.current_amount,
  aa.overdue_30_60,
  aa.overdue_60_90,
  aa.overdue_90_plus,
  aa.total,
  ab.overdue_amount,
  ab.oldest_overdue_date,
  ab.net_balance
FROM account_profiles ap
JOIN parties p ON p.id = ap.party_id
LEFT JOIN account_aging aa ON aa.account_profile_id = ap.id
LEFT JOIN account_balances ab ON ab.account_profile_id = ap.id
WHERE ap.party_role = 'CUSTOMER';

CREATE UNIQUE INDEX idx_cas_unique ON customer_aging_summary(tenant_id, party_id, currency);
CREATE INDEX idx_cas_overdue ON customer_aging_summary(tenant_id, overdue_90_plus DESC)
  WHERE overdue_90_plus > 0;


-- ============================================================================
-- supplier_aging_summary
-- ============================================================================

CREATE MATERIALIZED VIEW supplier_aging_summary AS
SELECT
  ap.tenant_id,
  ap.party_id,
  p.display_name AS supplier_name,
  ap.currency,
  ap.account_status,
  aa.current_amount,
  aa.overdue_30_60,
  aa.overdue_60_90,
  aa.overdue_90_plus,
  aa.total,
  ab.overdue_amount,
  ab.oldest_overdue_date,
  ab.net_balance
FROM account_profiles ap
JOIN parties p ON p.id = ap.party_id
LEFT JOIN account_aging aa ON aa.account_profile_id = ap.id
LEFT JOIN account_balances ab ON ab.account_profile_id = ap.id
WHERE ap.party_role = 'SUPPLIER';

CREATE UNIQUE INDEX idx_sas_unique ON supplier_aging_summary(tenant_id, party_id, currency);
CREATE INDEX idx_sas_overdue ON supplier_aging_summary(tenant_id, overdue_90_plus DESC)
  WHERE overdue_90_plus > 0;
