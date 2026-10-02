-- Sales may propose document prices. Finance and the customer must accept the same revision.
-- Existing quotes deliberately retain a null customer acceptance: never invent historical consent.
ALTER TABLE sales_quotes
    ADD COLUMN origin_quote_id UUID REFERENCES sales_quotes(id),
    ADD COLUMN customer_accepted_at TIMESTAMPTZ,
    ADD COLUMN customer_accepted_by UUID,
    ADD COLUMN customer_accepted_revision INTEGER,
    ADD COLUMN cancel_reason VARCHAR(500),
    ADD COLUMN cancelled_at TIMESTAMPTZ,
    ADD COLUMN cancelled_by UUID,
    ADD CONSTRAINT ck_sales_quotes_customer_acceptance CHECK (
        (customer_accepted_at IS NULL AND customer_accepted_by IS NULL AND customer_accepted_revision IS NULL)
        OR (customer_accepted_at IS NOT NULL AND customer_accepted_by IS NOT NULL
            AND customer_accepted_revision IS NOT NULL AND customer_accepted_revision >= 0
            AND customer_accepted_revision <= review_revision)),
    ADD CONSTRAINT ck_sales_quotes_cancellation CHECK (
        (cancelled_at IS NULL AND cancelled_by IS NULL AND cancel_reason IS NULL)
        OR (status = -1 AND cancelled_at IS NOT NULL AND cancelled_by IS NOT NULL
            AND cancel_reason IS NOT NULL AND length(btrim(cancel_reason)) > 0));

CREATE UNIQUE INDEX uq_sales_quotes_active_renegotiation
    ON sales_quotes(origin_quote_id)
    WHERE origin_quote_id IS NOT NULL AND NOT is_deleted AND status <> -1;

CREATE INDEX idx_sales_quote_revision_goods_history
    ON sales_quote_revision_logs USING gin(snapshot jsonb_path_ops)
    WHERE action IN ('SUBMIT', 'FINANCE_EDIT', 'CONFIRM');

ALTER TABLE sales_quote_items
    DROP CONSTRAINT sales_quote_items_price_source_check,
    DROP CONSTRAINT ck_sales_quote_items_finance_price,
    ADD CONSTRAINT sales_quote_items_price_source_check CHECK (price_source IN ('MASTER', 'SALES', 'FINANCE')),
    ADD CONSTRAINT ck_sales_quote_items_finance_price CHECK (price_source <> 'FINANCE' OR finance_price_at IS NOT NULL);

ALTER TABLE sales_quote_revision_logs
    DROP CONSTRAINT sales_quote_revision_logs_action_check,
    ADD CONSTRAINT sales_quote_revision_logs_action_check CHECK (action IN (
        'SUBMIT', 'WITHDRAW', 'FINANCE_EDIT', 'RETURN', 'CONFIRM', 'REOPEN', 'FINANCE_REOPEN',
        'SALES_EDIT', 'CUSTOMER_ACCEPT', 'CANCEL', 'CONVERT'));

COMMENT ON COLUMN sales_quote_items.price_source IS
    'MASTER master price snapshot / SALES proposed document price / FINANCE finance price; never writes goods.price';
COMMENT ON COLUMN sales_quotes.customer_accepted_revision IS
    'Revision accepted by the customer, recorded by the responsible salesperson; must equal review_revision to convert';
COMMENT ON COLUMN sales_quotes.cancel_reason IS
    'Sales negotiation lost/cancelled reason; original quote and immutable revision history remain retained';
