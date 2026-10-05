-- V802 (ADR-147): 车间内料仓开通单一真源 + 发料来源仓 + 直送只送已开通的车间。
--
-- 背景(2026-10-04 用户反馈):
--   1. 「仓库资料」里有「装配第一车间内料仓」, 内料仓总览却说装配第一车间「未启用」、内料仓列为空:
--      内料仓这个仓库行有三条建法(车间直送第一次时自动建 V595/ADR-089、开启整批领料时建、
--      仓库资料手工勾「内料仓」), 而页面判断「开通」只看整批领料设置; 业务清空又只清设置不清仓,
--      两处永远对不上。
--   2. 开启时选的「放在哪个主仓下」只列顶层仓(还混着不良品仓), 塑胶仓库是子仓永远选不到;
--      发料的「出库仓库」默认值三处各算一遍(内料仓页、申请候选、申请行建议仓), 口径各不相同。
--
-- 本迁移:
--   1. 新表 workshop_bins: 每个车间一行 = 这个车间的内料仓已开通(唯一真源)。bin_warehouse_id 是内料仓,
--      source_warehouse_id 是默认发料来源仓(可空, 空时按货品所属仓库)。内料仓仓库行只能由开通命令建出:
--      延迟约束保证每个未删除的内料仓恰有一条开通行; 一个车间最多一个未删除的内料仓(部分唯一索引)。
--   2. 三态: 未开通 -> 已开通(收车间直送) -> 已开通·整批领料。workshop_material_settings 只存整批领料
--      这个子能力, 用复合外键引用开通行(车间 + 内料仓), 字段与其余 30 多处引用都不变。
--   3. 存量回填: 有任何引用(流水、余额、直送、设置、单据等全部外键列, 外加物料分析参与仓)的内料仓
--      -> 已开通(来源仓为空; 有整批领料设置的仍是整批领料中); 一次都没用过的内料仓 -> 软删除
--      (NOTICE 列出); 同一车间还剩多个在用的内料仓 -> 中止, 交人工合并。
--   4. 车间直送不再自动建仓: 收料车间没开通内料仓时, fn_workshop_direct_targets 给出原因码
--      WORKSHOP_BIN_NOT_OPEN(大白话「{车间}还没开通内料仓, 请仓库在「车间内料仓」开通后再直送,
--      这次先送入仓库」), 报工分配据此把这部分送入仓库; 直送明细守卫要求内料仓就是该车间开通的那个。
--   5. 默认发料来源仓只算一次: fn_workshop_bin_default_source(内料仓, 货品, 颜色) = 来源仓有可发量 ->
--      货品所属仓库(可选良品子仓) -> 可发量最大的良品子仓; 都排除不良品仓与内料仓。
--   6. 仓库主档: 已开通的内料仓不能在仓库资料里停用/删除(fn_warehouse_selection_exit_blockers 改读开通行),
--      仍是某个内料仓发料来源仓的仓也要先改来源仓再停用。
--   7. 业务清空: workshop_bins 随仓库主档保留(PRESERVE); 整批领料设置、期间等仍清空。

LOCK TABLE warehouses IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE workshop_material_settings IN SHARE ROW EXCLUSIVE MODE;

-- ---------------------------------------------------------------------------
-- 1. 开通表
-- ---------------------------------------------------------------------------
CREATE TABLE workshop_bins (
    workshop_department_id UUID PRIMARY KEY REFERENCES departments(id),
    bin_warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    source_warehouse_id UUID REFERENCES warehouses(id),
    opened_by UUID REFERENCES users(id),
    opened_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by UUID REFERENCES users(id),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    row_version BIGINT NOT NULL DEFAULT 0,
    CONSTRAINT workshop_bins_bin_uk UNIQUE (bin_warehouse_id),
    CONSTRAINT workshop_bins_workshop_bin_uk UNIQUE (workshop_department_id, bin_warehouse_id),
    CONSTRAINT workshop_bins_source_not_bin_chk CHECK (source_warehouse_id IS DISTINCT FROM bin_warehouse_id)
);
CREATE INDEX idx_workshop_bins_source ON workshop_bins(source_warehouse_id) WHERE source_warehouse_id IS NOT NULL;
COMMENT ON TABLE workshop_bins IS
    'V802 (ADR-147) 车间内料仓开通记录(唯一真源): 一行 = 这个车间的内料仓已开通(可收车间直送); '
    '整批领料另由 workshop_material_settings 引用本行开启。内料仓仓库行只能由开通命令建出';
COMMENT ON COLUMN workshop_bins.bin_warehouse_id IS
    'V802 本车间的内料仓(仓库主档里 is_line_side 的那一行, 挂在主仓下)';
COMMENT ON COLUMN workshop_bins.source_warehouse_id IS
    'V802 默认发料来源仓(可空 = 按货品所属仓库); 只能是启用中的良品子仓, 发料默认值由 fn_workshop_bin_default_source 统一给出';
COMMENT ON COLUMN workshop_bins.opened_by IS 'V802 开通人; 存量回填行取整批领料开启人或建仓人, 可能为空';
COMMENT ON COLUMN workshop_bins.row_version IS
    'V802 开通状态版本: 改来源仓、开启/撤销整批领料都加一(页面按它判断是否被别人改过)';

-- ---------------------------------------------------------------------------
-- 2. 开通行守卫
-- ---------------------------------------------------------------------------
CREATE FUNCTION fn_guard_workshop_bin() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND (NEW.workshop_department_id IS DISTINCT FROM OLD.workshop_department_id
                             OR NEW.bin_warehouse_id IS DISTINCT FROM OLD.bin_warehouse_id) THEN
        RAISE EXCEPTION '内料仓开通记录的车间和内料仓不能改, 请撤销开通后重新开通'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_bins_identity_guard';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM departments workshop
        JOIN departments production_department
          ON production_department.id = workshop.parent_id AND production_department.code = 'DEPT_PROD'
         AND NOT production_department.is_deleted
        WHERE workshop.id = NEW.workshop_department_id AND NOT workshop.is_deleted) THEN
        RAISE EXCEPTION '内料仓只能给生产部下的车间开通'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_bins_workshop_guard';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM warehouses bin
        WHERE bin.id = NEW.bin_warehouse_id AND bin.is_line_side AND NOT bin.is_deleted
          AND bin.is_accountable AND NOT bin.is_defective
          AND bin.workshop_department_id = NEW.workshop_department_id) THEN
        RAISE EXCEPTION '开通记录只能指向本车间的内料仓'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_bins_bin_guard';
    END IF;
    IF NEW.source_warehouse_id IS NOT NULL
       AND (TG_OP = 'INSERT' OR NEW.source_warehouse_id IS DISTINCT FROM OLD.source_warehouse_id) THEN
        -- 与仓库停用互斥(同 V800 货品所属仓库守卫的锁法)。
        PERFORM 1 FROM warehouses WHERE id = NEW.source_warehouse_id FOR SHARE;
        IF NOT fn_warehouse_is_good_stock_leaf(NEW.source_warehouse_id) THEN
            RAISE EXCEPTION '发料来源仓只能选启用中的良品子仓, 不能是主仓、停用仓、不良品仓或车间内料仓'
                USING ERRCODE = '23514', CONSTRAINT = 'workshop_bins_source_guard';
        END IF;
    END IF;
    IF TG_OP = 'UPDATE' THEN
        IF NEW.row_version <> OLD.row_version + 1 THEN
            RAISE EXCEPTION '内料仓开通设置已被别人改过, 请刷新后再试'
                USING ERRCODE = '23514', CONSTRAINT = 'workshop_bins_version_guard';
        END IF;
        NEW.updated_at := now();
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_workshop_bin BEFORE INSERT OR UPDATE ON workshop_bins
    FOR EACH ROW EXECUTE FUNCTION fn_guard_workshop_bin();
COMMENT ON FUNCTION fn_guard_workshop_bin() IS
    'V802 开通行守卫: 生产部车间、本车间的内料仓、来源仓是可选良品子仓(写入或变化时)、车间与内料仓不可改、版本逐一递增';

-- ---------------------------------------------------------------------------
-- 3. 存量回填: 用过的内料仓 -> 已开通; 没用过的 -> 软删除; 同车间多个在用 -> 中止
-- ---------------------------------------------------------------------------
DO $backfill$
DECLARE
    line_side RECORD;
    reference RECORD;
    referenced BOOLEAN;
    problem TEXT;
    dropped TEXT;
BEGIN
    -- 整批领料设置指向的内料仓必须还是本车间未删除的内料仓, 否则建不出开通行。
    SELECT string_agg(COALESCE(bin.code, settings.periodic_bin_warehouse_id::text), ', ' ORDER BY bin.code)
      INTO problem
      FROM workshop_material_settings settings
      JOIN warehouses bin ON bin.id = settings.periodic_bin_warehouse_id
     WHERE bin.is_deleted OR NOT bin.is_line_side
        OR bin.workshop_department_id IS DISTINCT FROM settings.workshop_department_id;
    IF problem IS NOT NULL THEN
        RAISE EXCEPTION 'V802: 这些整批领料设置指向的内料仓已删除或不是本车间的内料仓, 请先人工处理: %', problem;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_constraint
                WHERE confrelid = 'warehouses'::regclass AND contype = 'f'
                  AND cardinality(conkey) <> 1) THEN
        RAISE EXCEPTION 'V802: 发现多列外键引用仓库, 请先更新本迁移的引用检查';
    END IF;

    CREATE TEMP TABLE v802_bins (id UUID PRIMARY KEY, code TEXT, workshop UUID, in_use BOOLEAN) ON COMMIT DROP;
    FOR line_side IN
        SELECT warehouse.id, warehouse.code, warehouse.workshop_department_id
          FROM warehouses warehouse
         WHERE warehouse.is_line_side AND NOT warehouse.is_deleted
         ORDER BY warehouse.code, warehouse.id
    LOOP
        referenced := EXISTS (SELECT 1 FROM stock_balances balance
                         WHERE balance.warehouse_id = line_side.id AND balance.qty <> 0)
             OR EXISTS (SELECT 1 FROM production_material_analyses analysis
                         WHERE line_side.id = ANY(analysis.participating_warehouse_ids));
        IF NOT referenced THEN
            FOR reference IN
                SELECT constraint_row.conrelid::regclass AS table_name, attribute.attname AS column_name
                  FROM pg_constraint constraint_row
                  JOIN pg_attribute attribute
                    ON attribute.attrelid = constraint_row.conrelid
                   AND attribute.attnum = constraint_row.conkey[1]
                 WHERE constraint_row.confrelid = 'warehouses'::regclass
                   AND constraint_row.contype = 'f'
                   AND NOT (constraint_row.conrelid = 'warehouses'::regclass)
                   AND NOT (constraint_row.conrelid = 'workshop_bins'::regclass)
            LOOP
                EXECUTE format('SELECT EXISTS (SELECT 1 FROM %s WHERE %I = $1)',
                               reference.table_name, reference.column_name)
                   INTO referenced USING line_side.id;
                EXIT WHEN referenced;
            END LOOP;
        END IF;
        INSERT INTO v802_bins VALUES (line_side.id, line_side.code, line_side.workshop_department_id, referenced);
    END LOOP;

    SELECT string_agg(codes, '; ') INTO problem FROM (
        SELECT string_agg(COALESCE(code, id::text), ' / ' ORDER BY code) AS codes
          FROM v802_bins WHERE in_use
         GROUP BY workshop HAVING count(*) > 1) duplicate_groups;
    IF problem IS NOT NULL THEN
        RAISE EXCEPTION 'V802: 同一个车间有多个在用的内料仓, 一个车间只能有一个, 请先人工合并: %', problem;
    END IF;

    INSERT INTO workshop_bins (workshop_department_id, bin_warehouse_id, source_warehouse_id, opened_by, opened_at)
    SELECT warehouse.workshop_department_id, warehouse.id, NULL,
           (SELECT account.id FROM users account
             WHERE account.id = COALESCE(settings.enabled_by, warehouse.created_by)),
           COALESCE(settings.enabled_at, warehouse.created_at, now())
      FROM v802_bins candidate
      JOIN warehouses warehouse ON warehouse.id = candidate.id
      LEFT JOIN workshop_material_settings settings ON settings.periodic_bin_warehouse_id = warehouse.id
     WHERE candidate.in_use
     ORDER BY warehouse.code, warehouse.id;

    SELECT string_agg(COALESCE(code, id::text), ', ' ORDER BY code) INTO dropped FROM v802_bins WHERE NOT in_use;
    UPDATE warehouses warehouse
       SET is_deleted = TRUE, deleted_at = now(), updated_at = now()
      FROM v802_bins candidate
     WHERE candidate.id = warehouse.id AND NOT candidate.in_use;
    IF dropped IS NOT NULL THEN
        RAISE NOTICE 'V802: 这些内料仓从来没用过, 已软删除(需要时在「车间内料仓」里重新开通): %', dropped;
    END IF;
END;
$backfill$;

-- 一个车间最多一个未删除的内料仓(V584 的同名普通索引被它取代)。
DROP INDEX IF EXISTS idx_warehouses_line_side_workshop;
CREATE UNIQUE INDEX ux_warehouses_line_side_workshop
    ON warehouses(workshop_department_id)
    WHERE is_line_side AND NOT is_deleted;

-- ---------------------------------------------------------------------------
-- 4. 内料仓仓库行与开通行同生共死(提交时校验; 开通命令先建仓再写开通行, 撤销时先删开通行再软删仓)
-- ---------------------------------------------------------------------------
CREATE FUNCTION fn_require_warehouse_line_side_opened(p_warehouse UUID) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    current RECORD;
BEGIN
    SELECT warehouse.id, warehouse.code, warehouse.name, warehouse.is_line_side, warehouse.is_deleted,
           warehouse.workshop_department_id
      INTO current
      FROM warehouses warehouse WHERE warehouse.id = p_warehouse;
    IF FOUND AND current.is_line_side AND NOT current.is_deleted AND NOT EXISTS (
        SELECT 1 FROM workshop_bins opened
         WHERE opened.bin_warehouse_id = current.id
           AND opened.workshop_department_id = current.workshop_department_id) THEN
        RAISE EXCEPTION '车间内料仓「%」没有开通记录: 内料仓只能在「车间内料仓」里开通或撤销',
            COALESCE(NULLIF(btrim(current.name), ''), current.code, '该仓库')
            USING ERRCODE = '23514', CONSTRAINT = 'warehouse_line_side_opening_guard';
    END IF;
END;
$$;
COMMENT ON FUNCTION fn_require_warehouse_line_side_opened(UUID) IS
    'V802 每个未删除的车间内料仓恰有一条本车间的开通行; 不满足即拒绝(按提交时的最新状态判定)';

CREATE FUNCTION fn_assert_warehouse_line_side_opened() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM fn_require_warehouse_line_side_opened(NEW.id);
    RETURN NULL;
END;
$$;
CREATE FUNCTION fn_assert_workshop_bin_withdrawn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM fn_require_warehouse_line_side_opened(OLD.bin_warehouse_id);
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_assert_warehouse_line_side_opened_ins
    AFTER INSERT ON warehouses DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW WHEN (NEW.is_line_side)
    EXECUTE FUNCTION fn_assert_warehouse_line_side_opened();
CREATE CONSTRAINT TRIGGER trg_assert_warehouse_line_side_opened_upd
    AFTER UPDATE OF is_line_side, is_deleted, workshop_department_id ON warehouses DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW WHEN (NEW.is_line_side AND NOT NEW.is_deleted)
    EXECUTE FUNCTION fn_assert_warehouse_line_side_opened();
CREATE CONSTRAINT TRIGGER trg_assert_workshop_bin_withdrawn
    AFTER DELETE ON workshop_bins DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_assert_workshop_bin_withdrawn();
COMMENT ON FUNCTION fn_assert_warehouse_line_side_opened() IS
    'V802 提交时校验: 新建内料仓或改内料仓身份后, 它必须有本车间的开通行';
COMMENT ON FUNCTION fn_assert_workshop_bin_withdrawn() IS
    'V802 提交时校验: 删掉开通行(撤销开通)时, 内料仓仓库行必须同一事务里软删除';

-- ---------------------------------------------------------------------------
-- 5. 整批领料设置只是开通后的子能力: 复合外键引用开通行
-- ---------------------------------------------------------------------------
ALTER TABLE workshop_material_settings
    ADD CONSTRAINT workshop_material_settings_opened_bin_fk
    FOREIGN KEY (workshop_department_id, periodic_bin_warehouse_id)
    REFERENCES workshop_bins (workshop_department_id, bin_warehouse_id);
COMMENT ON TABLE workshop_material_settings IS
    '车间整批领料设置 (ADR-131; V802 起只是已开通内料仓的子能力, 用复合外键引用 workshop_bins): '
    '指定的内料仓与启用日期在有进出记录后不可改; 停用只用来撤销设错的开启';

CREATE OR REPLACE FUNCTION fn_guard_workshop_material_settings() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM departments workshop
        JOIN departments production_department
          ON production_department.id = workshop.parent_id AND production_department.code = 'DEPT_PROD'
         AND NOT production_department.is_deleted
        WHERE workshop.id = NEW.workshop_department_id AND NOT workshop.is_deleted) THEN
        RAISE EXCEPTION '整批领料只能在生产部下的车间开启'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_settings_workshop_guard';
    END IF;
    -- V802: 整批领料只能开在本车间已开通的内料仓上(开通行是唯一真源; 复合外键兜底)。
    IF NEW.periodic_bin_warehouse_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM workshop_bins opened
        JOIN warehouses bin ON bin.id = opened.bin_warehouse_id
        WHERE opened.workshop_department_id = NEW.workshop_department_id
          AND opened.bin_warehouse_id = NEW.periodic_bin_warehouse_id
          AND bin.is_line_side AND NOT bin.is_deleted AND bin.is_accountable) THEN
        RAISE EXCEPTION '这个车间还没开通内料仓, 请先在「车间内料仓」开通'
            USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_settings_bin_guard';
    END IF;
    IF NEW.periodic_enabled AND NOT COALESCE(OLD.periodic_enabled, FALSE) THEN
        IF EXISTS (
            SELECT 1 FROM stock_balances balance
            JOIN goods material ON material.id = balance.goods_id AND material.issue_method = 'PERIODIC'
            WHERE balance.warehouse_id = NEW.periodic_bin_warehouse_id AND balance.qty <> 0) THEN
            RAISE EXCEPTION '这个内料仓里已经有整批领料的料, 请先清空再开启'
                USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_settings_enable_guard';
        END IF;
        IF EXISTS (
            SELECT 1 FROM workshop_material_periods period
            WHERE period.bin_warehouse_id = NEW.periodic_bin_warehouse_id AND period.status = 'CLOSED'
              AND period.end_date >= NEW.go_live_date) THEN
            RAISE EXCEPTION '启用日期必须晚于这个内料仓已结算的日期'
                USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_settings_enable_guard';
        END IF;
    END IF;
    IF TG_OP = 'UPDATE' THEN
        IF OLD.periodic_bin_warehouse_id IS NOT NULL
           AND (NEW.periodic_bin_warehouse_id IS DISTINCT FROM OLD.periodic_bin_warehouse_id
                OR NEW.go_live_date IS DISTINCT FROM OLD.go_live_date)
           AND EXISTS (SELECT 1 FROM v_workshop_material_bin_ledger ledger
                       WHERE ledger.bin_warehouse_id = OLD.periodic_bin_warehouse_id) THEN
            RAISE EXCEPTION '这个车间的内料仓已经有进出记录, 内料仓和启用日期不能再改'
                USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_settings_immutable_guard';
        END IF;
        IF OLD.periodic_enabled AND NOT NEW.periodic_enabled AND (
               EXISTS (SELECT 1 FROM v_workshop_material_bin_ledger ledger
                       WHERE ledger.bin_warehouse_id = OLD.periodic_bin_warehouse_id)
               OR EXISTS (SELECT 1 FROM production_execution_periodic_materials material_row
                          WHERE material_row.bin_warehouse_id = OLD.periodic_bin_warehouse_id)
               OR EXISTS (SELECT 1 FROM workshop_material_requisitions requisition
                          WHERE requisition.bin_warehouse_id = OLD.periodic_bin_warehouse_id
                            AND requisition.status = 'PENDING')) THEN
            RAISE EXCEPTION '这个车间的内料仓已经在用, 不能停用'
                USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_settings_disable_guard';
        END IF;
        IF NEW.row_version <> OLD.row_version + 1 THEN
            RAISE EXCEPTION '整批领料设置已被别人改过, 请刷新后再试'
                USING ERRCODE = '23514', CONSTRAINT = 'workshop_material_settings_version_guard';
        END IF;
        NEW.updated_at := now();
    END IF;
    RETURN NEW;
END;
$$;
COMMENT ON FUNCTION fn_guard_workshop_material_settings() IS
    'V740 车间整批领料设置守卫; V802 起整批领料只能开在本车间已开通(workshop_bins)的内料仓上';

-- ---------------------------------------------------------------------------
-- 6. 仓库退出新选(停用/删除/改不核算/改不良品仓)前置条件: 已开通的内料仓、仍是发料来源仓的仓
--    (取代 V800 的「已开启整批领料的内料仓」; 停用/删除的 fn_warehouse_retirement_blockers 自动带上)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_warehouse_selection_exit_blockers(p_warehouse UUID)
RETURNS TEXT[] LANGUAGE sql STABLE AS $$
    SELECT array_remove(ARRAY[
        (SELECT '还有 ' || count(DISTINCT balance.goods_id) || ' 种货品有库存'
           FROM stock_balances balance
          WHERE balance.warehouse_id = p_warehouse AND balance.qty <> 0
         HAVING count(*) > 0),
        (SELECT '还是 ' || count(*) || ' 个货品的所属仓库'
           FROM goods
          WHERE goods.owning_warehouse_id = p_warehouse AND NOT goods.is_deleted
         HAVING count(*) > 0),
        (SELECT '还有 ' || count(*) || ' 条没结束的库存预留'
           FROM stock_reservations reservation
          WHERE reservation.warehouse_id = p_warehouse AND reservation.status = 0
            AND NOT reservation.is_deleted
            AND reservation.qty - reservation.consumed_qty - reservation.released_qty > 0
         HAVING count(*) > 0),
        (SELECT '是已开通的车间内料仓, 请在「车间内料仓」里撤销开通'
           FROM workshop_bins opened
          WHERE opened.bin_warehouse_id = p_warehouse
          LIMIT 1),
        (SELECT '还是 ' || count(*) || ' 个车间内料仓的发料来源仓, 请先在「车间内料仓」改来源仓或恢复按货品所属仓库发料'
           FROM workshop_bins opened
          WHERE opened.source_warehouse_id = p_warehouse
         HAVING count(*) > 0)
    ], NULL)
$$;
COMMENT ON FUNCTION fn_warehouse_selection_exit_blockers(UUID) IS
    'V802 仓库退出新单可选(停用/删除/改不核算/改不良品仓)的前置条件: 库存、货品所属、未结预留、已开通的内料仓、内料仓发料来源仓';

-- 撤销开通(只撤销设错的开通)的前置条件; 返回给人看的原因(空数组 = 可以撤销)。
CREATE FUNCTION fn_workshop_bin_revoke_blockers(p_bin UUID)
RETURNS TEXT[] LANGUAGE sql STABLE AS $$
    SELECT array_remove(ARRAY[
        (SELECT '已开启整批领料, 请先撤销整批领料'
           FROM workshop_material_settings settings
          WHERE settings.periodic_bin_warehouse_id = p_bin AND settings.periodic_enabled
          LIMIT 1),
        (SELECT '已经有 ' || count(*) || ' 条进出记录'
           FROM stock_movements movement
          WHERE movement.warehouse_id = p_bin
         HAVING count(*) > 0),
        (SELECT '还有 ' || count(DISTINCT balance.goods_id) || ' 种料有库存'
           FROM stock_balances balance
          WHERE balance.warehouse_id = p_bin AND balance.qty <> 0
         HAVING count(*) > 0),
        (SELECT '已经收过 ' || count(*) || ' 次车间直送'
           FROM production_workshop_direct_transfers transfer
          WHERE transfer.line_side_warehouse_id = p_bin
         HAVING count(*) > 0),
        (SELECT '还有 ' || count(DISTINCT document.id) || ' 张库存单据用到它'
           FROM stock_documents document
          WHERE NOT document.is_deleted
            AND (document.warehouse_id = p_bin OR document.to_warehouse_id = p_bin
                 OR EXISTS (SELECT 1 FROM stock_document_items line
                             WHERE line.doc_id = document.id AND line.warehouse_id = p_bin))
         HAVING count(*) > 0),
        (SELECT '还有 ' || count(*) || ' 条没结束的库存预留'
           FROM stock_reservations reservation
          WHERE reservation.warehouse_id = p_bin AND reservation.status = 0 AND NOT reservation.is_deleted
         HAVING count(*) > 0),
        (SELECT '已经有 ' || count(*) || ' 张内料仓领料或退回单'
           FROM workshop_material_requisitions requisition
          WHERE requisition.bin_warehouse_id = p_bin
         HAVING count(*) > 0)
    ], NULL)
$$;
COMMENT ON FUNCTION fn_workshop_bin_revoke_blockers(UUID) IS
    'V802 撤销开通的前置条件(只撤销设错的开通): 没开整批领料、没有进出、没有余额、没收过直送、没有单据/预留/领料单引用';

-- ---------------------------------------------------------------------------
-- 7. 车间直送: 收料车间没开通内料仓时不能直送(原因码 WORKSHOP_BIN_NOT_OPEN)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_workshop_direct_reason_rank(p_code TEXT)
RETURNS INTEGER LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_code
        WHEN 'QTY_EXCEEDS_REMAINING' THEN 10
        WHEN 'SOURCE_SHARE_USED_UP' THEN 20
        WHEN 'DEMAND_ALREADY_COVERED' THEN 21
        -- V802: 收料车间没开通内料仓。整个车间的上层工单都卡在这一条上, 排在接收状态类原因之前,
        -- 一个都不能送时界面优先说它(办法是去开通或这次送入仓库)。
        WHEN 'WORKSHOP_BIN_NOT_OPEN' THEN 25
        WHEN 'RECEIVER_STATUS' THEN 30
        WHEN 'PLAN_NOT_ACTIVE' THEN 31
        WHEN 'PACKAGE_NOT_CONFIRMED' THEN 32
        WHEN 'DEMAND_CLOSED' THEN 33
        WHEN 'DIFFERENT_WORKSHOP' THEN 40
        WHEN 'SUBCONTRACT_ROUTE' THEN 50
        WHEN 'BUY_ROUTE' THEN 51
        WHEN 'NO_PARENT_RELATION' THEN 60
        WHEN 'SELF' THEN 61
        WHEN 'GOODS_MISMATCH' THEN 62
        WHEN 'SOURCE_INVALID' THEN 63
        WHEN 'TARGET_INVALID' THEN 64
        WHEN 'NO_RECEIVER_ISSUED_YET' THEN 70
        WHEN 'NOT_A_COMPONENT' THEN 71
        ELSE 0
    END
$$;
COMMENT ON FUNCTION fn_workshop_direct_reason_rank(TEXT) IS
    'V736 不可直送原因的接近程度(数字越小越接近可送); V802 加 WORKSHOP_BIN_NOT_OPEN';

CREATE OR REPLACE FUNCTION fn_workshop_direct_reason_text(
    p_code TEXT, p_receiver TEXT, p_goods TEXT, p_workshop TEXT, p_state TEXT,
    p_qty NUMERIC, p_remaining NUMERIC)
RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT CASE p_code
        WHEN 'QTY_EXCEEDS_REMAINING' THEN format('%s本次基本数量 %s 超过最多可送 %s，超出部分请送入仓库或分给其它上层工单',
            CASE WHEN p_receiver IS NULL THEN '' ELSE '转给' || p_receiver || ' 的' END,
            trim_scale(p_qty), trim_scale(GREATEST(COALESCE(p_remaining, 0), 0)))
        WHEN 'SOURCE_SHARE_USED_UP' THEN '本工单承担的份额已全部交接 (同计划行拆出的工单共用额度)'
        WHEN 'DEMAND_ALREADY_COVERED' THEN format('%s的 %s 已经备齐 (仓库备料或其它直送)', receiver, goods)
        WHEN 'RECEIVER_STATUS' THEN format('%s%s，不再接收直送', receiver, COALESCE(p_state, '已开工或已结束'))
        WHEN 'PLAN_NOT_ACTIVE' THEN format('%s的生产计划%s', receiver, COALESCE(p_state, '已停用'))
        WHEN 'PACKAGE_NOT_CONFIRMED' THEN format('%s的计划包已取消，不再接收直送', receiver)
        WHEN 'DEMAND_CLOSED' THEN format('%s已不再需要 %s', receiver, goods)
        WHEN 'WORKSHOP_BIN_NOT_OPEN' THEN format('%s还没开通内料仓，请仓库在「车间内料仓」开通后再直送，这次先送入仓库',
            COALESCE(p_workshop, '收料车间'))
        WHEN 'DIFFERENT_WORKSHOP' THEN format('%s在%s，跨车间必须送入仓库', receiver, COALESCE(p_workshop, '其它车间'))
        WHEN 'SUBCONTRACT_ROUTE' THEN format('%s 是委外件：做好后先送入仓库，发外加工回来后，上层工单再从仓库领料', goods)
        WHEN 'BUY_ROUTE' THEN format('%s的 %s 按采购供应，只能从仓库领料', receiver, goods)
        WHEN 'NO_PARENT_RELATION' THEN format('%s的 %s 不是由本工单供应 (属于别的物料分析或已由其它来源承担)', receiver, goods)
        WHEN 'SELF' THEN '不能转给本工单自己'
        WHEN 'GOODS_MISMATCH' THEN '所选上层工单需要的不是这个货品'
        WHEN 'SOURCE_INVALID' THEN '报工来源工单已失效，请刷新后重试'
        WHEN 'TARGET_INVALID' THEN '所选上层工单已失效，请刷新后重新选择'
        WHEN 'NO_RECEIVER_ISSUED_YET' THEN '上层工单还没下达到车间，暂时没有可接收的工单'
        WHEN 'NOT_A_COMPONENT' THEN '本工单做的是顶层产品，没有下一道工序，请送入仓库'
        -- 以下只用于报工送入仓库的那部分(output_route_reason)，不是「不可转」原因。
        WHEN 'USER_CHOSEN' THEN '报工时选择送入仓库'
        WHEN 'RECEIVERS_FULL' THEN '能直送的上层工单都已分满，其余送入仓库'
        WHEN 'PUBLIC_SHARE' THEN '计划内的公共备货部分，统一送入仓库'
        WHEN 'ACTUAL_SURPLUS' THEN '超出计划的实际产量，统一送入仓库'
    END
    -- 有接收工单称呼时带一个空格接后文(「上层工单 ZX… 在二车间」)，没有时直接接(「上层工单在其它车间」)。
    FROM (SELECT CASE WHEN p_receiver IS NULL THEN '上层工单' ELSE p_receiver || ' ' END AS receiver,
                 COALESCE(NULLIF(p_goods, ''), '这个货品') AS goods) context
$$;
COMMENT ON FUNCTION fn_workshop_direct_reason_text(TEXT, TEXT, TEXT, TEXT, TEXT, NUMERIC, NUMERIC) IS
    'V736 不可直送原因与报工送仓原因的大白话(唯一一份文案); V802 加「车间还没开通内料仓」';

CREATE OR REPLACE FUNCTION fn_workshop_direct_targets(
    p_producing UUID, p_demand UUID DEFAULT NULL, p_base_qty NUMERIC DEFAULT NULL)
RETURNS TABLE(
    demand_id UUID, receiving_segment_id UUID, receiving_segment_code TEXT, receiving_status TEXT,
    receiving_continuous BOOLEAN, receiving_plan_id UUID, receiving_plan_no TEXT,
    receiving_product_goods_id UUID, receiving_workshop_id UUID,
    demand_warehouse_id UUID, package_warehouse_id UUID,
    required_qty NUMERIC, covered_qty NUMERIC, receiver_shortfall_qty NUMERIC, remaining_qty NUMERIC,
    receiver_open BOOLEAN, eligible BOOLEAN, reason_code TEXT, reason_text TEXT, reason_rank INTEGER,
    sort_order INTEGER, receiver_label TEXT)
LANGUAGE sql STABLE AS $$
WITH producing AS MATERIALIZED (
    -- 与 fn_workshop_direct_relation_code 的 SOURCE_INVALID 同一口径(工单或其计划已删即失效)。
    SELECT segment.id, segment.product_goods_id, segment.plan_id, segment.source_plan_item_id
    FROM production_execution_segments segment
    JOIN production_plans plan ON plan.id = segment.plan_id
    WHERE segment.id = p_producing AND NOT segment.is_deleted AND NOT plan.is_deleted
), scope AS MATERIALIZED (
    SELECT p_demand AS demand_id WHERE p_demand IS NOT NULL
    UNION
    SELECT linked.demand_id
    FROM fn_workshop_direct_linked_demands(p_producing) linked
    WHERE p_demand IS NULL AND NOT linked.receiving_plan_canceled
), structured AS MATERIALIZED (
    SELECT scope.demand_id,
           demand.status AS demand_status, demand.required_qty AS demand_required,
           demand.warehouse_id AS demand_warehouse, demand.need_date, demand.goods_id AS demand_goods,
           receiving.id AS receiving_id, receiving.segment_code, receiving.status AS segment_status,
           COALESCE(receiving.continuous_supply, FALSE) AS continuous,
           receiving.workshop_department_id AS receiving_workshop, receiving.product_goods_id AS receiving_product,
           plan.id AS plan_id, plan.bill_no, plan.status AS plan_status, plan.is_deleted AS plan_deleted,
           plan.is_stopped, plan.is_closed, plan.is_canceled, plan.delivery_date AS plan_delivery,
           package.id AS package_id, package.status AS package_status, package.is_deleted AS package_deleted,
           package.warehouse_id AS package_warehouse,
           item.line_priority, item.delivery_date AS item_delivery,
           fn_workshop_direct_relation_code(p_producing, scope.demand_id) AS structure_code
    FROM scope
    LEFT JOIN production_material_demands demand ON demand.id = scope.demand_id
    LEFT JOIN production_execution_segments receiving ON receiving.id = demand.execution_segment_id
    LEFT JOIN production_plans plan ON plan.id = receiving.plan_id
    LEFT JOIN production_planning_packages package
      ON package.id = receiving.package_id AND package.plan_id = plan.id
    LEFT JOIN production_material_analysis_items item ON item.id = plan.material_analysis_item_id
), stated AS MATERIALIZED (
    SELECT structured.*,
           COALESCE(structure_code, CASE
               -- V802: 收料车间没开通内料仓就没有收料的地方(不再第一次直送时自动建仓)。
               WHEN NOT EXISTS (SELECT 1 FROM workshop_bins opened
                                WHERE opened.workshop_department_id = structured.receiving_workshop)
                    THEN 'WORKSHOP_BIN_NOT_OPEN'
               WHEN plan_deleted OR is_canceled OR is_closed OR is_stopped
                    OR plan_status IS DISTINCT FROM 1 THEN 'PLAN_NOT_ACTIVE'
               WHEN package_id IS NULL OR package_deleted
                    OR package_status IS DISTINCT FROM 'CONFIRMED' THEN 'PACKAGE_NOT_CONFIRMED'
               WHEN NOT COALESCE(segment_status IN ('WAITING', 'READY', 'DISPATCHED')
                                 OR (segment_status = 'IN_PROGRESS' AND continuous), FALSE) THEN 'RECEIVER_STATUS'
               WHEN demand_status IN ('RELEASED', 'REVERSED') THEN 'DEMAND_CLOSED'
           END) AS state_code
    FROM structured
), measured AS MATERIALIZED (
    SELECT stated.*,
           CASE WHEN state_code IS NULL THEN fn_workshop_direct_covered_base_qty(stated.demand_id) END AS covered,
           CASE WHEN state_code IS NULL THEN fn_workshop_direct_remaining_for_source(p_producing, stated.demand_id) END AS remaining
    FROM stated
), coded AS (
    SELECT measured.*,
           '上层工单' || COALESCE(' ' || measured.segment_code, '') AS receiver_label,
           COALESCE(state_code, CASE
               WHEN demand_status = 'FULFILLED' OR demand_required - covered <= 0 THEN 'DEMAND_ALREADY_COVERED'
               WHEN remaining <= 0 THEN 'SOURCE_SHARE_USED_UP'
               WHEN p_base_qty IS NOT NULL AND p_base_qty > remaining THEN 'QTY_EXCEEDS_REMAINING'
           END) AS code
    FROM measured
), described AS (
    SELECT coded.*,
           row_number() OVER (ORDER BY coded.line_priority NULLS LAST,
                                       COALESCE(coded.item_delivery, coded.need_date, coded.plan_delivery) NULLS LAST,
                                       coded.bill_no NULLS LAST, coded.segment_code NULLS LAST,
                                       coded.demand_id::text)::INTEGER AS ordinal,
           fn_workshop_direct_reason_text(coded.code, coded.receiver_label,
               COALESCE(NULLIF(goods.code, ''), NULLIF(goods.name, ''), '这个货品'),
               COALESCE(workshop.name, '其它车间'),
               CASE coded.code
                   WHEN 'PLAN_NOT_ACTIVE' THEN CASE
                       WHEN coded.plan_deleted OR coded.is_canceled THEN '已取消'
                       WHEN coded.is_closed THEN '已结案'
                       WHEN coded.is_stopped THEN '已暂停'
                       ELSE '未审核' END
                   WHEN 'RECEIVER_STATUS' THEN CASE coded.segment_status
                       WHEN 'IN_PROGRESS' THEN '已按齐套开工'
                       WHEN 'COMPLETED' THEN '已完工'
                       ELSE '已取消' END
               END,
               p_base_qty, coded.remaining) AS text
    FROM coded
    LEFT JOIN goods ON goods.id = COALESCE(coded.demand_goods,
        (SELECT product_goods_id FROM production_execution_segments WHERE id = p_producing))
    LEFT JOIN departments workshop ON workshop.id = coded.receiving_workshop
), listed AS (
    SELECT described.demand_id, described.receiving_id, described.segment_code, described.segment_status,
           described.continuous, described.plan_id, described.bill_no, described.receiving_product,
           described.receiving_workshop, described.demand_warehouse, described.package_warehouse,
           described.demand_required, described.covered,
           CASE WHEN described.covered IS NULL THEN NULL
                ELSE GREATEST(described.demand_required - described.covered, 0) END AS shortfall,
           GREATEST(COALESCE(described.remaining, 0), 0) AS source_remaining,
           described.state_code IS NULL AS open, described.code IS NULL AS allowed, described.code, described.text,
           fn_workshop_direct_reason_rank(described.code) AS code_rank, described.ordinal,
           described.receiver_label
    FROM described
    -- 列表只列结构上的上层(可送，或说得出它现在为什么不能收)。不是上层的行(没有父子关系、本身无效)
    -- 不列，也就不会挡住哨兵、不会被当成不可转原因；单条校验照常返回那一行与它的原因。
    WHERE p_demand IS NOT NULL
       OR described.code IS NULL
       OR described.code NOT IN ('NO_PARENT_RELATION', 'SELF', 'GOODS_MISMATCH', 'SOURCE_INVALID', 'TARGET_INVALID')
)
SELECT * FROM listed
UNION ALL
SELECT NULL::UUID, NULL::UUID, NULL::TEXT, NULL::TEXT, FALSE, NULL::UUID, NULL::TEXT, NULL::UUID, NULL::UUID,
       NULL::UUID, NULL::UUID, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, 0::NUMERIC,
       FALSE, FALSE, sentinel.code,
       fn_workshop_direct_reason_text(sentinel.code, NULL, sentinel.goods_label, NULL, NULL, NULL, NULL),
       fn_workshop_direct_reason_rank(sentinel.code), 1, NULL::TEXT
FROM (
    SELECT CASE
               WHEN NOT EXISTS (SELECT 1 FROM producing) THEN 'SOURCE_INVALID'
               WHEN fn_workshop_direct_source_is_subcontract(p_producing) THEN 'SUBCONTRACT_ROUTE'
               WHEN EXISTS (
                       SELECT 1 FROM producing
                       JOIN production_plans plan ON plan.id = producing.plan_id
                       JOIN production_material_analysis_items item
                         ON item.id = plan.material_analysis_item_id
                        AND item.analysis_id = plan.material_analysis_id AND NOT item.is_deleted
                       WHERE item.source_type IN ('MAKE_COMPONENT', 'SUBCONTRACT_MAKE', 'AGGREGATE_MAKE'))
                    OR EXISTS (
                       SELECT 1 FROM producing JOIN subplan_links link
                         ON link.subplan_id = producing.plan_id AND NOT link.is_deleted)
                    OR EXISTS (
                       SELECT 1 FROM producing JOIN production_material_supply_pegs peg
                         ON peg.supply_type = 'PRODUCTION_PLAN_ITEM'
                        AND peg.supply_item_id = producing.source_plan_item_id
                        AND peg.status <> 'REVERSED') THEN 'NO_RECEIVER_ISSUED_YET'
               ELSE 'NOT_A_COMPONENT'
           END AS code,
           (SELECT COALESCE(NULLIF(goods.code, ''), NULLIF(goods.name, ''), '这个货品')
            FROM producing JOIN goods ON goods.id = producing.product_goods_id) AS goods_label
) sentinel
-- 没有一条结构上的上层时才出哨兵(上面已把不是上层的行剔除)。生产侧是委外件时挂钩的行都是委外原因，
-- 一条都没有也由哨兵点名「委外件」。
WHERE p_demand IS NULL AND NOT EXISTS (SELECT 1 FROM listed)
ORDER BY 21
$$;
COMMENT ON FUNCTION fn_workshop_direct_targets(UUID, UUID, NUMERIC) IS
    'V736 车间直送候选与单条校验唯一入口; V802 起收料车间没开通内料仓时原因码 WORKSHOP_BIN_NOT_OPEN';

ALTER TABLE production_daily_report_items
    DROP CONSTRAINT production_daily_report_items_output_route_reason_chk,
    ADD CONSTRAINT production_daily_report_items_output_route_reason_chk CHECK (
        output_route_reason IS NULL OR (destination = 'WAREHOUSE' AND output_route_reason IN (
            'USER_CHOSEN', 'RECEIVERS_FULL', 'PUBLIC_SHARE', 'ACTUAL_SURPLUS',
            'SOURCE_SHARE_USED_UP', 'DEMAND_ALREADY_COVERED', 'RECEIVER_STATUS', 'PLAN_NOT_ACTIVE',
            'PACKAGE_NOT_CONFIRMED', 'DEMAND_CLOSED', 'WORKSHOP_BIN_NOT_OPEN', 'DIFFERENT_WORKSHOP',
            'SUBCONTRACT_ROUTE', 'BUY_ROUTE', 'NO_PARENT_RELATION', 'SELF', 'GOODS_MISMATCH', 'SOURCE_INVALID',
            'TARGET_INVALID', 'NO_RECEIVER_ISSUED_YET', 'NOT_A_COMPONENT')));

CREATE OR REPLACE FUNCTION fn_guard_workshop_direct_transfer_item()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'workshop direct transfer items cannot be deleted'
            USING ERRCODE = '55000';
    END IF;
    IF TG_OP = 'UPDATE' THEN
        IF OLD.reversal_id IS NOT NULL
           OR NEW.reversal_id IS NULL
           OR (to_jsonb(NEW) - 'reversal_id')
              IS DISTINCT FROM (to_jsonb(OLD) - 'reversal_id') THEN
            RAISE EXCEPTION 'a workshop direct transfer item is immutable apart from one reversal stamp'
                USING ERRCODE = '55000';
        END IF;
        RETURN NEW;
    END IF;

    -- 去向必须真的是「转送车间」，数量必须等于该报工行的申报量(一行报工对一条接收需求)。
    IF NOT EXISTS (
            SELECT 1 FROM production_daily_report_items item
            WHERE item.id = NEW.source_report_item_id
              AND item.destination = 'WORKSHOP'
              AND item.is_deleted = FALSE
              AND item.qty = NEW.qty) THEN
        RAISE EXCEPTION 'a workshop direct transfer must mirror one whole WORKSHOP-destined report line'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'workshop_direct_transfer_item_source_guard';
    END IF;

    -- 收料需求必须属于收料工单，且货品/颜色与这条报工行一致。
    IF NOT EXISTS (
            SELECT 1
            FROM production_material_demands demand
            JOIN production_daily_report_items item
              ON item.id = NEW.source_report_item_id
            WHERE demand.id = NEW.to_demand_id
              AND demand.execution_segment_id = NEW.to_execution_segment_id
              AND demand.is_deleted = FALSE
              AND demand.goods_id = item.goods_id
              AND demand.color_id IS NOT DISTINCT FROM item.color_id) THEN
        RAISE EXCEPTION 'a workshop direct transfer must point at one live demand of the same goods'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'workshop_direct_transfer_item_demand_guard';
    END IF;

    -- 直送单头的车间就是出料工单的车间；内料仓必须是这个车间开通的那一个(V802 workshop_bins)，
    -- 且与收料需求同主仓(fn_warehouse_same_main 是同主仓分仓领料的硬前提，V489)。
    IF NOT EXISTS (
            SELECT 1
            FROM production_workshop_direct_transfers transfer
            JOIN workshop_bins opened
              ON opened.bin_warehouse_id = transfer.line_side_warehouse_id
             AND opened.workshop_department_id = transfer.workshop_department_id
            JOIN warehouses line_side
              ON line_side.id = opened.bin_warehouse_id
            JOIN production_material_demands demand ON demand.id = NEW.to_demand_id
            JOIN production_daily_report_items item
              ON item.id = NEW.source_report_item_id
            JOIN production_execution_segments producing
              ON producing.id = item.execution_segment_id
            WHERE transfer.id = NEW.transfer_id
              AND line_side.is_line_side
              AND line_side.is_deleted = FALSE
              AND line_side.workshop_department_id = transfer.workshop_department_id
              AND producing.workshop_department_id = transfer.workshop_department_id
              AND fn_warehouse_same_main(line_side.id, demand.warehouse_id)) THEN
        RAISE EXCEPTION 'workshop direct transfer requires the opened workshop bin under the demand main warehouse'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'workshop_direct_transfer_item_workshop_guard';
    END IF;
    RETURN NEW;
END;
$$;
COMMENT ON FUNCTION fn_guard_workshop_direct_transfer_item() IS
    'V736 直送明细身份守卫; V802 起内料仓必须是出料车间在 workshop_bins 里开通的那一个';

-- ---------------------------------------------------------------------------
-- 8. 默认发料来源仓(只算一次): 来源仓有可发量 -> 货品所属仓库 -> 可发量最大的良品子仓
-- ---------------------------------------------------------------------------
-- 可发量 = v_stock_usable 的按仓可用量(账面减去指定本仓的未了结预留, ADR-146 单一口径)。
-- 内料仓没开通(申请先于开通)时 p_bin 为空, 直接从第二步起算。都不满足返回空(页面要人选)。
CREATE FUNCTION fn_workshop_bin_default_source(p_bin UUID, p_goods UUID, p_color UUID)
RETURNS UUID LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT opened.source_warehouse_id
           FROM workshop_bins opened
           JOIN v_stock_usable usable
             ON usable.warehouse_id = opened.source_warehouse_id
            AND usable.goods_id = p_goods
            AND usable.color_id IS NOT DISTINCT FROM p_color
          WHERE opened.bin_warehouse_id = p_bin
            AND usable.available_qty > 0
            AND fn_warehouse_is_good_stock_leaf(opened.source_warehouse_id)
          LIMIT 1),
        (SELECT goods.owning_warehouse_id
           FROM goods
          WHERE goods.id = p_goods
            AND goods.owning_warehouse_id IS DISTINCT FROM p_bin
            AND fn_warehouse_is_good_stock_leaf(goods.owning_warehouse_id)),
        (SELECT usable.warehouse_id
           FROM v_stock_usable usable
          WHERE usable.goods_id = p_goods
            AND usable.color_id IS NOT DISTINCT FROM p_color
            AND usable.available_qty > 0
            AND usable.warehouse_id IS DISTINCT FROM p_bin
            AND fn_warehouse_is_good_stock_leaf(usable.warehouse_id)
          ORDER BY usable.available_qty DESC, usable.warehouse_id
          LIMIT 1))
$$;
COMMENT ON FUNCTION fn_workshop_bin_default_source(UUID, UUID, UUID) IS
    'V802 内料仓发料的默认出库仓(唯一定义): 来源仓有可发量 -> 货品所属仓库(可选良品子仓) -> 可发量最大的良品子仓; '
    '内料仓页候选、申请候选、申请行建议仓、直接发料默认值都只调它';

-- ---------------------------------------------------------------------------
-- 9. 审计与业务清空分类
-- ---------------------------------------------------------------------------
SELECT fn_audit_track_table('workshop_bins', 'FULL', 'data_change', false);

DO $reset_policy$
DECLARE definition TEXT; anchor TEXT := '(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition) - length(replace(definition, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'V802 business_data_reset policy anchor changed';
    END IF;
    EXECUTE replace(definition, anchor, anchor || E',\n            (''workshop_bins'', ''PRESERVE'')');
END;
$reset_policy$;

COMMENT ON COLUMN warehouses.is_line_side IS
    'V802 车间内料仓: 只能由「车间内料仓」的开通命令建出, 每个未删除的内料仓恰有一条 workshop_bins 开通行, '
    '一个车间最多一个; 不计入公共可用量与即时库存';

-- ---------------------------------------------------------------------------
-- 10. 事后断言
-- ---------------------------------------------------------------------------
DO $assert$
BEGIN
    IF EXISTS (SELECT 1 FROM warehouses warehouse
                WHERE warehouse.is_line_side AND NOT warehouse.is_deleted
                  AND NOT EXISTS (SELECT 1 FROM workshop_bins opened
                                   WHERE opened.bin_warehouse_id = warehouse.id
                                     AND opened.workshop_department_id = warehouse.workshop_department_id)) THEN
        RAISE EXCEPTION 'V802 assertion: every live workshop bin warehouse needs exactly one opening row';
    END IF;
    IF EXISTS (SELECT 1 FROM workshop_bins opened
                JOIN warehouses warehouse ON warehouse.id = opened.bin_warehouse_id
               WHERE warehouse.is_deleted OR NOT warehouse.is_line_side) THEN
        RAISE EXCEPTION 'V802 assertion: an opening row points at a deleted or ordinary warehouse';
    END IF;
    IF EXISTS (SELECT 1 FROM workshop_material_settings settings
                WHERE settings.periodic_enabled
                  AND NOT EXISTS (SELECT 1 FROM workshop_bins opened
                                   WHERE opened.workshop_department_id = settings.workshop_department_id
                                     AND opened.bin_warehouse_id = settings.periodic_bin_warehouse_id)) THEN
        RAISE EXCEPTION 'V802 assertion: periodic issuing is enabled on a workshop whose bin is not opened';
    END IF;
END;
$assert$;
