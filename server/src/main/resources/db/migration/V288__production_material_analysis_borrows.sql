-- V288: 物料分析现货层借用（调货）记录
--
-- 业务语义：同一物料分析内，把某条 BOM 路径节点上已分配的合格现货覆盖量
-- 显式调拨给另一产品的同物料路径节点（"这批料先给 X 产品用"）。
-- 只影响分析软分配与套件可生产量投影，不写 stock_reservations、不动库存账本。
-- 撤销只允许 ACTIVE → REVOKED，追加式留痕，不物理删除。

CREATE TABLE production_material_analysis_borrows (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    analysis_id         UUID NOT NULL
        REFERENCES production_material_analyses(id) ON DELETE RESTRICT,
    from_material_id    UUID NOT NULL,
    to_material_id      UUID NOT NULL,
    goods_id            UUID NOT NULL REFERENCES goods(id) ON DELETE RESTRICT,
    color_id            UUID REFERENCES colors(id) ON DELETE RESTRICT,
    unit_id             UUID NOT NULL REFERENCES units(id) ON DELETE RESTRICT,
    qty                 NUMERIC(18,4) NOT NULL,
    reason              TEXT NOT NULL,
    status              TEXT NOT NULL DEFAULT 'ACTIVE',
    last_effective_qty  NUMERIC(18,4) NOT NULL DEFAULT 0,
    idempotency_key     TEXT NOT NULL,
    created_by          UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_by          UUID REFERENCES users(id) ON DELETE RESTRICT,
    revoked_at          TIMESTAMPTZ,
    revoke_reason       TEXT,
    CONSTRAINT analysis_borrow_qty_chk CHECK (qty > 0),
    CONSTRAINT analysis_borrow_status_chk
        CHECK (status IN ('ACTIVE', 'REVOKED')),
    CONSTRAINT analysis_borrow_distinct_chk
        CHECK (from_material_id <> to_material_id),
    CONSTRAINT analysis_borrow_reason_chk
        CHECK (reason = btrim(reason) AND length(reason) BETWEEN 2 AND 1000),
    CONSTRAINT analysis_borrow_effective_chk
        CHECK (last_effective_qty >= 0 AND last_effective_qty <= qty),
    CONSTRAINT analysis_borrow_key_chk
        CHECK (idempotency_key = btrim(idempotency_key)
            AND length(idempotency_key) BETWEEN 8 AND 128),
    CONSTRAINT analysis_borrow_revoke_chk CHECK (
        (status = 'ACTIVE'
            AND revoked_by IS NULL AND revoked_at IS NULL
            AND revoke_reason IS NULL)
        OR
        (status = 'REVOKED'
            AND revoked_by IS NOT NULL AND revoked_at IS NOT NULL
            AND revoke_reason IS NOT NULL
            AND revoke_reason = btrim(revoke_reason)
            AND length(revoke_reason) BETWEEN 2 AND 1000)
    ),
    CONSTRAINT analysis_borrow_from_owner_fk
        FOREIGN KEY (analysis_id, from_material_id)
        REFERENCES production_material_analysis_materials(analysis_id, id)
        ON DELETE RESTRICT,
    CONSTRAINT analysis_borrow_to_owner_fk
        FOREIGN KEY (analysis_id, to_material_id)
        REFERENCES production_material_analysis_materials(analysis_id, id)
        ON DELETE RESTRICT
);

CREATE UNIQUE INDEX uq_analysis_borrow_idempotency
    ON production_material_analysis_borrows(analysis_id, idempotency_key);

CREATE INDEX idx_analysis_borrow_from
    ON production_material_analysis_borrows(from_material_id)
    WHERE status = 'ACTIVE';

CREATE INDEX idx_analysis_borrow_to
    ON production_material_analysis_borrows(to_material_id)
    WHERE status = 'ACTIVE';
