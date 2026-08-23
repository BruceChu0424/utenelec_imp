-- V310: explicitly attach the standard business audit trigger to the two V309
-- ledgers.  The preceding V308 migration already proves full public coverage;
-- this forward migration limits its write scope to the newly introduced tables.

CREATE TRIGGER trg_audit_preplan_material_reallocations
    AFTER INSERT OR UPDATE OR DELETE ON preplan_material_reallocations
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

CREATE TRIGGER trg_audit_preplan_stock_entitlement_events
    AFTER INSERT OR UPDATE OR DELETE ON preplan_stock_entitlement_events
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
