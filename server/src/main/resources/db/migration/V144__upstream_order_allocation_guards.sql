-- V144: serialize and backstop request/application -> order cumulative
-- quantities.
--
-- Approval services lock the source request/application rows in UUID order
-- before checking remaining quantity. These triggers protect imports,
-- maintenance SQL, and future code paths as well. Historical over-allocation
-- may be corrected, but no further increase beyond the source quantity is
-- accepted (fn_guard_processed_quantity was introduced in V132).

CREATE TRIGGER trg_purchase_request_ordered_guard
    BEFORE INSERT OR UPDATE OF ordered_qty
    ON purchase_request_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_processed_quantity(
        'ordered_qty', 'qty', '');

CREATE TRIGGER trg_subcontract_application_ordered_guard
    BEFORE INSERT OR UPDATE OF ordered_qty
    ON subcontract_application_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_processed_quantity(
        'ordered_qty', 'qty', '');
