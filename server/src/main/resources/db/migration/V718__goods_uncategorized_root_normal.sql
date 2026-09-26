-- =====================================================================
-- V718：货品「未分类」根放开为普通分类（2026-09-25 用户口径）
-- =====================================================================
-- 背景：货品资料左树的「未分类」根（LEGACY_ORPHAN，V275 起系统保留：不可改名/
-- 不可软删/不可物理删，注册表 FK RESTRICT + 不可变触发器双保险）。用户要求它
-- 就是普通分类——改名去括号英文、有权限即可编辑/删除（删除仍走既有引用保护：
-- 分类下还有货品时会被拦，须先挪走）。
--
-- 只放开货品根；客户/模具/供应商三个系统根的保护（触发器 + 注册表列）原样保留。
--
-- 改动：
--   ① 退役 material_categories 上的未分类保护触发器（fn_protect_uncategorized_
--      master_category 在注册列置空后会 RAISE 'missing'，必须一并退役）；
--   ② 注册表 material_category_id 置空（否则 FK RESTRICT 拦删除）：先撤注册表
--      不可变触发器、放开 NOT NULL，置空后重建「窄守卫」——仍禁删、禁改其他列，
--      material_category_id 只许单向从非空改为空，防回填；
--   ③ 改名「未分类（历史孤儿）」→「未分类」（左树显示不再带括号与英文快照，
--      与其他三类主档根同名；code=LEGACY_ORPHAN 保留作身份，不影响显示——
--      前端 2026-09-25 起对未分类 code 不再拼「名称(编码)」后缀）。
--
-- 幂等：IF EXISTS / 条件 UPDATE，重跑安全。不加表。
-- =====================================================================

-- ① 货品未分类根的专属保护触发器退役（client/mould/supplier 的同款触发器不动）。
DROP TRIGGER IF EXISTS trg_material_categories_protect_uncategorized ON material_categories;

-- ② 注册表脱钩：先撤不可变触发器，放开 NOT NULL，置空 material_category_id。
DROP TRIGGER IF EXISTS trg_protect_system_master_category_registry ON system_master_category_registry;
ALTER TABLE system_master_category_registry
    ALTER COLUMN material_category_id DROP NOT NULL;
UPDATE system_master_category_registry
SET material_category_id = NULL,
    updated_at = now()
WHERE id = '27500000-0000-4000-8000-000000000001'::uuid
  AND material_category_id IS NOT NULL;

-- 窄守卫：仍禁删；UPDATE 只许「material_category_id 非空→空 + updated_at 刷新」
-- 这一件事，其余任何列变化都拒绝（注册表其余三列继续不可变）。
CREATE OR REPLACE FUNCTION fn_protect_system_master_category_registry()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.id IS DISTINCT FROM OLD.id
       OR NEW.client_category_id IS DISTINCT FROM OLD.client_category_id
       OR NEW.mould_category_id IS DISTINCT FROM OLD.mould_category_id
       OR NEW.supplier_category_id IS DISTINCT FROM OLD.supplier_category_id
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
       OR NEW.created_by IS DISTINCT FROM OLD.created_by
       OR NEW.updated_by IS DISTINCT FROM OLD.updated_by
       OR (NEW.material_category_id IS NOT NULL
           AND NEW.material_category_id IS DISTINCT FROM OLD.material_category_id) THEN
        RAISE EXCEPTION
            'system master category UUID registry is immutable (material_category_id may only be cleared)';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_protect_system_master_category_registry
    BEFORE UPDATE ON system_master_category_registry
    FOR EACH ROW EXECUTE FUNCTION fn_protect_system_master_category_registry();

CREATE TRIGGER trg_protect_system_master_category_registry_no_delete
    BEFORE DELETE ON system_master_category_registry
    FOR EACH ROW EXECUTE FUNCTION fn_protect_system_master_category_registry();

-- ③ 改名（触发行级审计触发器照常记录；version +1 让持有旧版本编辑页的人乐观锁失败）。
UPDATE material_categories
SET name = '未分类',
    version = version + 1
WHERE legacy_id = -1
  AND legacy_code_snapshot = 'LEGACY_ORPHAN'
  AND is_deleted = FALSE
  AND name IS DISTINCT FROM '未分类';
