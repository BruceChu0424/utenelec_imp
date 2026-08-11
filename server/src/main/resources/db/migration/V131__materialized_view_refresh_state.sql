-- Track the freshness of reporting materialized views.
-- The application refreshes these views concurrently and serializes work across
-- multiple application instances with a PostgreSQL advisory lock.

CREATE TABLE IF NOT EXISTS report_materialized_view_refresh_state (
    view_name           varchar(80) PRIMARY KEY,
    status              varchar(16) NOT NULL DEFAULT 'PENDING',
    last_started_at     timestamptz,
    last_succeeded_at   timestamptz,
    last_failed_at      timestamptz,
    last_duration_ms    bigint,
    last_error          varchar(2000),
    refreshed_by        varchar(160),
    CONSTRAINT report_mv_refresh_status_chk
        CHECK (status IN ('PENDING', 'RUNNING', 'SUCCESS', 'FAILED')),
    CONSTRAINT report_mv_refresh_duration_chk
        CHECK (last_duration_ms IS NULL OR last_duration_ms >= 0)
);

INSERT INTO report_materialized_view_refresh_state (view_name)
VALUES ('finance_ar_ap_mv'),
       ('production_monthly_mv'),
       ('purchase_monthly_mv'),
       ('sales_monthly_mv'),
       ('stock_monthly_mv'),
       ('subcontract_monthly_mv')
ON CONFLICT (view_name) DO NOTHING;

COMMENT ON TABLE report_materialized_view_refresh_state IS
    'Operational freshness and failure state for reporting materialized views';
