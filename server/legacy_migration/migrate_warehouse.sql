-- =====================================================================
-- 仓库主档迁移(ADR-145)：老库 B_Storage + 审过的仓库对照表 → warehouses(不依赖 server 启动)
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh --warehouse-data
-- 前提：V798 已应用(唯一主仓 + 直属子仓两层的守卫与函数)。
-- 来源：老库 B_Storage(data/warehouse.csv，6 条)+ server/legacy_migration/warehouse_crosswalk.csv
--   (入库审过的对照表，不含个人信息)。对照表每一行说清楚一个老库仓 id 去哪里：
--     SPLIT  老库主仓 132 → 001 主仓(只作汇总；库存明细与余额按货品所属子仓拆分，见 migrate_stock_docs.sql)
--     KEEP   老库在用仓 → 同编号子仓
--     MERGE  老库已禁用仓 → 并入在用的目标仓(不单独建行；目标仓状态取「使用」)
--     DROP   老库已删除仓 → 不建仓、不写目标；落在它上面的单据与余额不迁(写对账清单，见各模块脚本)
--     TARGET 新 ERP 子仓(老库没有对应仓，如塑胶仓库/包材仓库/五金车间)
-- 规则：
--   - 不再 DELETE FROM warehouses：按编号增量写入目标仓，重导不会把层级打平，也不会把用户
--     启用的仓改回禁用；状态一律取目标值「使用」；
--   - 主仓是 SPLIT 行的目标仓，其余目标仓固定挂在主仓下(两层)；
--   - 不良品仓按对照表(002、C0401)标记，不再按名称 LIKE '%不良%' 猜；
--   - warehouse.csv 里出现、对照表里没有的仓直接中止；库里还留着旧的「迁移自动补录」仓库存根时中止。
--   字段映射(来自 B_Storage)：ID→legacy_id、Location→location、Remark→remark、
--   IsCal→is_accountable(⚠ 取反：老库 IsCal=0=参与核算)、WorkID→legacy_operator_id(Sys_Operator.ID；
--   旧误命名影子同步保留)。编号/名称/用途/状态取对照表的目标值。文本字段做 BTRIM + 空串→NULL。
-- =====================================================================

SELECT set_config('app.business_identifier_legacy_import', 'on', true);

CREATE TEMP TABLE warehouse_stage (
    legacy_id          int,
    code               text,        -- Number
    name               text,        -- Storage_Name
    location           text,        -- Location
    remark             text,        -- Remark
    is_accountable     boolean,     -- IsCal
    workshop_legacy_id int,         -- WorkID -> Sys_Operator.ID (compatibility snapshot)
    status             text         -- Status
) ON COMMIT DROP;
\copy warehouse_stage FROM '/tmp/warehouse.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE warehouse_crosswalk_stage (
    legacy_id        int,
    legacy_code      text,
    legacy_name      text,
    action           text,
    target_code      text,
    target_name      text,
    target_defective boolean,
    note             text
) ON COMMIT DROP;
\copy warehouse_crosswalk_stage FROM '/tmp/warehouse_crosswalk.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- ---------------- 对照表自身与老库仓的一致性(失败关闭) ----------------
DO $$
DECLARE
    problem TEXT;
BEGIN
    SELECT string_agg(DISTINCT COALESCE(action, '<空>'), ', ') INTO problem
      FROM warehouse_crosswalk_stage
     WHERE action IS NULL OR action NOT IN ('SPLIT', 'KEEP', 'MERGE', 'DROP', 'TARGET');
    IF problem IS NOT NULL THEN
        RAISE EXCEPTION 'warehouse crosswalk has unknown actions: %', problem;
    END IF;
    IF EXISTS (SELECT 1 FROM warehouse_crosswalk_stage
                WHERE (action = 'TARGET') <> (legacy_id IS NULL)
                   OR (action = 'DROP') <> (NULLIF(btrim(target_code), '') IS NULL)
                   OR (action = 'DROP' AND (NULLIF(btrim(target_name), '') IS NOT NULL OR target_defective IS NOT NULL))
                   OR (action <> 'DROP' AND (NULLIF(btrim(target_name), '') IS NULL OR target_defective IS NULL))) THEN
        RAISE EXCEPTION 'warehouse crosswalk rows need a legacy id (except TARGET); DROP rows name no target, every other row names a target code, name and use';
    END IF;
    SELECT string_agg(legacy_id::text, ', ') INTO problem FROM (
        SELECT legacy_id FROM warehouse_crosswalk_stage WHERE legacy_id IS NOT NULL
         GROUP BY legacy_id HAVING count(*) > 1) duplicate_ids;
    IF problem IS NOT NULL THEN
        RAISE EXCEPTION 'warehouse crosswalk repeats legacy ids: %', problem;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM warehouse_crosswalk_stage) THEN
        IF EXISTS (SELECT 1 FROM warehouse_stage) THEN
            RAISE EXCEPTION 'warehouse.csv has rows but the warehouse crosswalk is empty';
        END IF;
        RETURN;
    END IF;
    IF (SELECT count(*) FROM warehouse_crosswalk_stage WHERE action = 'SPLIT') <> 1 THEN
        RAISE EXCEPTION 'warehouse crosswalk must name exactly one SPLIT row (the legacy main warehouse)';
    END IF;
    IF EXISTS (SELECT 1 FROM warehouse_crosswalk_stage WHERE action = 'SPLIT' AND target_defective) THEN
        RAISE EXCEPTION 'the main warehouse cannot be a defective-stock warehouse';
    END IF;
    SELECT string_agg(target_code, ', ') INTO problem FROM (
        SELECT target_code FROM warehouse_crosswalk_stage WHERE action <> 'DROP'
         GROUP BY target_code
        HAVING count(DISTINCT target_name) > 1 OR count(DISTINCT target_defective) > 1
            OR count(*) FILTER (WHERE action IN ('SPLIT', 'KEEP', 'MERGE')) > 1) inconsistent;
    IF problem IS NOT NULL THEN
        RAISE EXCEPTION 'warehouse crosswalk targets need one name, one use and at most one legacy source: %', problem;
    END IF;
    SELECT string_agg(stage.legacy_id::text, ', ' ORDER BY stage.legacy_id) INTO problem
      FROM warehouse_stage stage
     WHERE NOT EXISTS (SELECT 1 FROM warehouse_crosswalk_stage crosswalk
                        WHERE crosswalk.legacy_id = stage.legacy_id AND crosswalk.action <> 'TARGET');
    IF problem IS NOT NULL THEN
        RAISE EXCEPTION 'B_Storage rows missing from warehouse_crosswalk.csv: %', problem;
    END IF;
    SELECT string_agg(crosswalk.legacy_id::text, ', ' ORDER BY crosswalk.legacy_id) INTO problem
      FROM warehouse_crosswalk_stage crosswalk
     WHERE crosswalk.action IN ('SPLIT', 'KEEP', 'MERGE')
       AND NOT EXISTS (SELECT 1 FROM warehouse_stage stage WHERE stage.legacy_id = crosswalk.legacy_id);
    IF problem IS NOT NULL THEN
        RAISE EXCEPTION 'warehouse crosswalk keeps legacy ids that are not in B_Storage: %', problem;
    END IF;
    SELECT string_agg(COALESCE(warehouse.code, warehouse.id::text), ', ') INTO problem
      FROM warehouses warehouse
     WHERE NOT warehouse.is_deleted AND warehouse.legacy_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM warehouse_crosswalk_stage crosswalk
                        WHERE crosswalk.legacy_id = warehouse.legacy_id
                          AND crosswalk.action IN ('SPLIT', 'KEEP', 'MERGE'));
    IF problem IS NOT NULL THEN
        RAISE EXCEPTION 'old legacy warehouse stubs are still active, clean them up first: %', problem;
    END IF;
END;
$$;

-- ---------------- 目标仓按编号增量写入(主仓先写, 其余挂主仓下) ----------------
DO $$
DECLARE
    target RECORD;
    root_code TEXT;
    root_id UUID;
    existing UUID;
BEGIN
    SELECT target_code INTO root_code FROM warehouse_crosswalk_stage WHERE action = 'SPLIT';
    IF root_code IS NULL THEN
        RETURN;
    END IF;
    FOR target IN
        SELECT crosswalk.target_code AS code,
               max(crosswalk.target_name) AS name,
               bool_or(crosswalk.target_defective) AS defective,
               max(crosswalk.legacy_id) FILTER (WHERE crosswalk.action IN ('SPLIT', 'KEEP', 'MERGE')) AS legacy_id,
               max(NULLIF(BTRIM(stage.location, ' ' || chr(12288)), '')) AS location,
               max(NULLIF(BTRIM(stage.remark, ' ' || chr(12288)), '')) AS remark,
               -- ⚠ IsCal 语义反转：老库 IsCal=0 表示「参与库存核算」，故取反；新 ERP 子仓一律参与核算。
               COALESCE(bool_and(NOT COALESCE(stage.is_accountable, FALSE)), TRUE) AS accountable,
               max(NULLIF(stage.workshop_legacy_id, 0)) AS operator_legacy_id,
               (array_agg(link.workshop_department_id) FILTER (WHERE link.workshop_department_id IS NOT NULL))[1]
                   AS workshop_department_id
          FROM warehouse_crosswalk_stage crosswalk
          LEFT JOIN warehouse_stage stage
            ON stage.legacy_id = crosswalk.legacy_id AND crosswalk.action IN ('SPLIT', 'KEEP', 'MERGE')
          -- Only a reviewed B_Storage.ID crosswalk may restore the workshop UUID relationship.
          -- B_Storage.WorkID is Sys_Operator.ID and must never be joined to workshops.
          LEFT JOIN legacy_warehouse_workshop_links link ON link.warehouse_legacy_id = stage.legacy_id
         WHERE crosswalk.action <> 'DROP'
         GROUP BY crosswalk.target_code
         ORDER BY (crosswalk.target_code = root_code) DESC, crosswalk.target_code
    LOOP
        existing := NULL;
        SELECT id INTO existing FROM warehouses
         WHERE code = target.code AND NOT is_deleted
         ORDER BY created_at LIMIT 1;
        IF existing IS NULL AND target.legacy_id IS NOT NULL THEN
            SELECT id INTO existing FROM warehouses
             WHERE legacy_id = target.legacy_id AND NOT is_deleted;
        END IF;
        IF existing IS NULL THEN
            INSERT INTO warehouses (
                legacy_id, code, name, location, remark, is_accountable, is_defective,
                workshop_legacy_id, legacy_operator_id, workshop_department_id,
                parent_id, status, auto_created)
            VALUES (
                target.legacy_id, target.code, target.name, target.location, target.remark,
                target.accountable, target.defective,
                target.operator_legacy_id, target.operator_legacy_id, target.workshop_department_id,
                CASE WHEN target.code = root_code THEN NULL ELSE root_id END, '使用', FALSE)
            RETURNING id INTO existing;
        ELSE
            UPDATE warehouses SET
                code = target.code,
                name = target.name,
                legacy_id = COALESCE(target.legacy_id, legacy_id),
                location = CASE WHEN target.legacy_id IS NULL THEN location ELSE target.location END,
                remark = CASE WHEN target.legacy_id IS NULL THEN remark ELSE target.remark END,
                is_accountable = target.accountable,
                is_defective = target.defective,
                workshop_legacy_id = CASE WHEN target.legacy_id IS NULL THEN workshop_legacy_id
                                          ELSE target.operator_legacy_id END,
                legacy_operator_id = CASE WHEN target.legacy_id IS NULL THEN legacy_operator_id
                                          ELSE target.operator_legacy_id END,
                workshop_department_id = CASE WHEN target.legacy_id IS NULL THEN workshop_department_id
                                              ELSE target.workshop_department_id END,
                parent_id = CASE WHEN target.code = root_code THEN NULL ELSE root_id END,
                status = '使用',
                auto_created = FALSE,
                updated_at = now()
             WHERE id = existing
               AND (code, name, legacy_id, location, remark, is_accountable, is_defective,
                    workshop_legacy_id, legacy_operator_id, workshop_department_id,
                    parent_id, status, auto_created)
                   IS DISTINCT FROM
                   (target.code, target.name, COALESCE(target.legacy_id, legacy_id),
                    CASE WHEN target.legacy_id IS NULL THEN location ELSE target.location END,
                    CASE WHEN target.legacy_id IS NULL THEN remark ELSE target.remark END,
                    target.accountable, target.defective,
                    CASE WHEN target.legacy_id IS NULL THEN workshop_legacy_id ELSE target.operator_legacy_id END,
                    CASE WHEN target.legacy_id IS NULL THEN legacy_operator_id ELSE target.operator_legacy_id END,
                    CASE WHEN target.legacy_id IS NULL THEN workshop_department_id
                         ELSE target.workshop_department_id END,
                    CASE WHEN target.code = root_code THEN NULL ELSE root_id END, '使用', FALSE);
        END IF;
        IF target.code = root_code THEN
            root_id := existing;
        END IF;
    END LOOP;
    IF fn_warehouse_root_id() IS DISTINCT FROM root_id THEN
        RAISE EXCEPTION 'warehouse master did not converge to the single main warehouse %', root_code;
    END IF;
END;
$$;


SELECT '✔ 仓库 总 ' || count(*) ||
       '，主仓 ' || count(*) FILTER (WHERE parent_id IS NULL) ||
       '，子仓 ' || count(*) FILTER (WHERE parent_id IS NOT NULL) ||
       '，不良品仓 ' || count(*) FILTER (WHERE is_defective) ||
       '，禁用 ' || count(*) FILTER (WHERE status = N'禁用') ||
       '，核算 ' || count(*) FILTER (WHERE is_accountable) AS 结果
FROM warehouses
WHERE NOT is_deleted;
