-- 厚度/单重单位补齐 UUID 真源；legacy id 仅保留迁移兼容。
ALTER TABLE goods
    ADD COLUMN IF NOT EXISTS thickness_unit_id UUID,
    ADD COLUMN IF NOT EXISTS m_weight_unit_id UUID;

-- 先安装 future-write FK，再回填。这样即使 goods 已有审计/业务触发器，
-- 也不会在 UPDATE 后因 pending trigger events 再 ALTER TABLE。
-- PostgreSQL 没有 ADD CONSTRAINT IF NOT EXISTS：显式核验同名约束，正确则幂等跳过，
-- 同名但结构错误则 fail closed，不能把错误约束误认为已完成。
DO $$
DECLARE
    v_definition TEXT;
    v_validated BOOLEAN;
BEGIN
    SELECT pg_get_constraintdef(c.oid), c.convalidated
    INTO v_definition, v_validated
    FROM pg_constraint c
    WHERE c.conrelid = 'goods'::regclass
      AND c.conname = 'fk_goods_thickness_unit';

    IF v_definition IS NULL THEN
        ALTER TABLE goods
            ADD CONSTRAINT fk_goods_thickness_unit
            FOREIGN KEY (thickness_unit_id)
            REFERENCES units(id) ON DELETE RESTRICT NOT VALID;
    ELSIF v_definition NOT IN (
        'FOREIGN KEY (thickness_unit_id) REFERENCES units(id) ON DELETE RESTRICT',
        'FOREIGN KEY (thickness_unit_id) REFERENCES units(id) ON DELETE RESTRICT NOT VALID'
    ) THEN
        RAISE EXCEPTION
            'constraint goods.fk_goods_thickness_unit has unexpected definition: %',
            v_definition USING ERRCODE = '55000';
    END IF;
    IF NOT COALESCE(v_validated, FALSE) THEN
        ALTER TABLE goods VALIDATE CONSTRAINT fk_goods_thickness_unit;
    END IF;

    SELECT pg_get_constraintdef(c.oid), c.convalidated
    INTO v_definition, v_validated
    FROM pg_constraint c
    WHERE c.conrelid = 'goods'::regclass
      AND c.conname = 'fk_goods_m_weight_unit';

    IF v_definition IS NULL THEN
        ALTER TABLE goods
            ADD CONSTRAINT fk_goods_m_weight_unit
            FOREIGN KEY (m_weight_unit_id)
            REFERENCES units(id) ON DELETE RESTRICT NOT VALID;
    ELSIF v_definition NOT IN (
        'FOREIGN KEY (m_weight_unit_id) REFERENCES units(id) ON DELETE RESTRICT',
        'FOREIGN KEY (m_weight_unit_id) REFERENCES units(id) ON DELETE RESTRICT NOT VALID'
    ) THEN
        RAISE EXCEPTION
            'constraint goods.fk_goods_m_weight_unit has unexpected definition: %',
            v_definition USING ERRCODE = '55000';
    END IF;
    IF NOT COALESCE(v_validated, FALSE) THEN
        ALTER TABLE goods VALIDATE CONSTRAINT fk_goods_m_weight_unit;
    END IF;
END;
$$;

-- 只回填 legacy_id 唯一可判定的单位，禁止按名称猜测。
WITH unique_units AS (
    SELECT legacy_id, (array_agg(id ORDER BY id))[1] AS id
    FROM units
    WHERE legacy_id IS NOT NULL
    GROUP BY legacy_id
    HAVING count(*) = 1
)
UPDATE goods g
SET thickness_unit_id = u.id
FROM unique_units u
WHERE g.thickness_unit_id IS NULL
  AND g.thickness_unit_legacy_id IS NOT NULL
  AND g.thickness_unit_legacy_id <> 0
  AND g.thickness_unit_legacy_id = u.legacy_id;

WITH unique_units AS (
    SELECT legacy_id, (array_agg(id ORDER BY id))[1] AS id
    FROM units
    WHERE legacy_id IS NOT NULL
    GROUP BY legacy_id
    HAVING count(*) = 1
)
UPDATE goods g
SET m_weight_unit_id = u.id
FROM unique_units u
WHERE g.m_weight_unit_id IS NULL
  AND g.m_weight_unit_legacy_id IS NOT NULL
  AND g.m_weight_unit_legacy_id <> 0
  AND g.m_weight_unit_legacy_id = u.legacy_id;

CREATE INDEX IF NOT EXISTS idx_goods_thickness_unit_id
    ON goods(thickness_unit_id) WHERE thickness_unit_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_goods_m_weight_unit_id
    ON goods(m_weight_unit_id) WHERE m_weight_unit_id IS NOT NULL;

COMMENT ON COLUMN goods.thickness_unit_id IS
    '厚度单位 UUID 真源 -> units.id；legacy 列仅用于旧数据兼容';
COMMENT ON COLUMN goods.m_weight_unit_id IS
    '单重单位 UUID 真源 -> units.id；legacy 列仅用于旧数据兼容';
