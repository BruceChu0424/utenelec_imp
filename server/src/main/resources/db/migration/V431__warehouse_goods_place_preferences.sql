-- V431: warehouse-scoped placement suggestions learned explicitly from an
-- append-only production finished-arrival registration.  This is a future
-- default only: inventory dimensions and historical place snapshots do not
-- depend on this table.
CREATE TABLE warehouse_goods_place_preferences (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    warehouse_id             UUID NOT NULL
        REFERENCES warehouses(id) ON DELETE RESTRICT,
    goods_id                 UUID NOT NULL
        REFERENCES goods(id) ON DELETE RESTRICT,
    color_id                 UUID
        REFERENCES colors(id) ON DELETE RESTRICT,
    place                    TEXT NOT NULL,
    selection_count          BIGINT NOT NULL DEFAULT 1,
    version                  BIGINT NOT NULL DEFAULT 0,
    source_registration_id   UUID NOT NULL
        REFERENCES production_finished_arrival_registrations(id)
        ON DELETE RESTRICT,
    source_registered_at     TIMESTAMPTZ NOT NULL,
    last_selected_by         UUID NOT NULL
        REFERENCES employees(id) ON DELETE RESTRICT,
    last_selected_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by               UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,
    updated_by               UUID NOT NULL
        REFERENCES users(id) ON DELETE RESTRICT,
    CONSTRAINT warehouse_goods_place_preference_place_chk CHECK (
        place = btrim(place)
        AND length(place) BETWEEN 1 AND 100),
    CONSTRAINT warehouse_goods_place_preference_count_chk CHECK (
        selection_count > 0),
    CONSTRAINT warehouse_goods_place_preference_version_chk CHECK (
        version >= 0),
    CONSTRAINT warehouse_goods_place_preference_dimension_uk
        UNIQUE NULLS NOT DISTINCT (warehouse_id, goods_id, color_id)
);

CREATE INDEX idx_warehouse_goods_place_preference_source
    ON warehouse_goods_place_preferences(source_registration_id);
CREATE INDEX idx_warehouse_goods_place_preference_goods
    ON warehouse_goods_place_preferences(goods_id, color_id, warehouse_id);

CREATE TRIGGER trg_set_updated_at_warehouse_goods_place_preferences
    BEFORE UPDATE ON warehouse_goods_place_preferences
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TRIGGER trg_audit_warehouse_goods_place_preferences
    AFTER INSERT OR UPDATE OR DELETE
    ON warehouse_goods_place_preferences
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

COMMENT ON TABLE warehouse_goods_place_preferences IS
    '仓库×货品×颜色共享建议库位；不承载库存数量，不改写历史快照，业务重置随来源登记清空';
COMMENT ON COLUMN warehouse_goods_place_preferences.place IS
    '仓库显式记忆的未来登记建议；实际库位仍以每次登记 place_snapshot 为准';
COMMENT ON COLUMN warehouse_goods_place_preferences.selection_count IS
    '成功采用不同且较新来源登记的次数；同一 registration 重放不增加';
COMMENT ON COLUMN warehouse_goods_place_preferences.source_registration_id IS
    '最近一次成功学习的 append-only 生产成品送检登记 UUID';
COMMENT ON COLUMN warehouse_goods_place_preferences.source_registered_at IS
    '最近学习来源登记的不可变创建时间，与 UUID 一起阻止旧来源覆盖新偏好';
COMMENT ON COLUMN warehouse_goods_place_preferences.version IS
    '偏好行版本；每次接受较新来源时递增';
