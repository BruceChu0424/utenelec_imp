-- Learn one explainable default production workshop per finished good.
-- The preference is only a future scheduling default; confirmed execution
-- segments remain the immutable source of what was actually arranged.
CREATE TABLE production_goods_workshop_preferences (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    goods_id                 UUID NOT NULL
        REFERENCES goods(id) ON DELETE RESTRICT,
    workshop_department_id   UUID NOT NULL
        REFERENCES departments(id) ON DELETE RESTRICT,
    selection_count          BIGINT NOT NULL DEFAULT 1,
    last_selected_by         UUID NOT NULL
        REFERENCES employees(id) ON DELETE RESTRICT,
    last_selected_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_prod_goods_workshop_pref_goods UNIQUE (goods_id),
    CONSTRAINT ck_prod_goods_workshop_pref_count
        CHECK (selection_count > 0)
);

CREATE INDEX idx_prod_goods_workshop_pref_workshop
    ON production_goods_workshop_preferences(workshop_department_id);

COMMENT ON TABLE production_goods_workshop_preferences IS
    'Learned finished-good workshop default; confirmed segments remain history';
COMMENT ON COLUMN production_goods_workshop_preferences.selection_count IS
    'Count of successful package confirmations or later assignment selections';

CREATE TRIGGER trg_set_updated_at_production_goods_workshop_preferences
    BEFORE UPDATE ON production_goods_workshop_preferences
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TRIGGER trg_audit_production_goods_workshop_preferences
    AFTER INSERT OR UPDATE OR DELETE
    ON production_goods_workshop_preferences
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
