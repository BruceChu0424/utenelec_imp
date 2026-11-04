ALTER TABLE sales_shipments ADD COLUMN finance_auditor_name_snapshot text;
ALTER TABLE sales_shipments ADD COLUMN warehouse_approver_name_snapshot text;
ALTER TABLE sales_shipment_finance_release_events ADD COLUMN actor_employee_id uuid REFERENCES employees(id);
ALTER TABLE sales_shipment_finance_release_events ADD COLUMN actor_name_snapshot text;
ALTER TABLE sales_shipment_finance_release_events ADD COLUMN actual_receipt_context jsonb;
ALTER TABLE sales_shipment_finance_release_events ADD COLUMN print_context jsonb;
-- Historical actors cannot be relabeled as an original-time name using today's personnel directory.
COMMENT ON COLUMN sales_shipments.finance_auditor_name_snapshot IS '审核当时姓名；历史未留存保持NULL，不以当前姓名冒充原快照';
CREATE INDEX idx_finance_receipts_customer_actual_review ON finance_receipts(client_id,currency_id,bank_booked_at,id)
    WHERE status=1 AND NOT is_deleted;
