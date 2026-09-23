-- V673 (ADR-105) production_plan_costs 由 34 个按年分区改为普通单表。
--
-- 这张表是老系统 F_PlanCostItem 的只读快照(约 136 万行), 只有遗留导入写入、只有
-- ProductionWhereUsedQueryService 按 goods_id 读取(不带日期时无法分区裁剪)。按年分区是按
-- 「持续写入的大表」设计的, 这里只带来 34 份索引和触发器克隆。改为单表后:
--   · 主键回到 (id), 老系统编号唯一键回到 (legacy_id), 父子行终于可以建自引用外键;
--   · 索引只留反查用的部分覆盖索引 + 外键检查需要的几条;
--   · 语句级守卫: 只有遗留导入会话(app.legacy_import='on')能写, 清空业务数据走 TRUNCATE 不受影响。
-- 行审计按 V670 清单为 NONE(遗留只读数据由导入对账脚本核对)。

ALTER TABLE public.production_plan_costs RENAME TO production_plan_costs_v648;

CREATE TABLE public.production_plan_costs
    (LIKE public.production_plan_costs_v648 INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING COMMENTS);

INSERT INTO public.production_plan_costs SELECT * FROM public.production_plan_costs_v648;

ALTER TABLE public.production_plan_costs ADD CONSTRAINT production_plan_costs_pk PRIMARY KEY (id);
ALTER TABLE public.production_plan_costs ADD CONSTRAINT uq_production_plan_costs_legacy UNIQUE (legacy_id);
ALTER TABLE public.production_plan_costs
    ADD CONSTRAINT production_plan_costs_goods_fk FOREIGN KEY (goods_id) REFERENCES public.goods(id),
    ADD CONSTRAINT production_plan_costs_color_fk FOREIGN KEY (color_id) REFERENCES public.colors(id),
    ADD CONSTRAINT production_plan_costs_master_goods_fk FOREIGN KEY (master_goods_id) REFERENCES public.goods(id),
    ADD CONSTRAINT production_plan_costs_master_color_fk FOREIGN KEY (master_color_id) REFERENCES public.colors(id),
    ADD CONSTRAINT production_plan_costs_supplier_fk FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id),
    ADD CONSTRAINT production_plan_costs_parent_fk FOREIGN KEY (parent_id) REFERENCES public.production_plan_costs(id);

COMMENT ON TABLE public.production_plan_costs IS
    '生产计划成本 / BOM 展开表(源 F_PlanCostItem 约 136 万行, 普通单表); 只读遗留快照, 只允许遗留导入写入';

-- 保留旧表上的非审计触发器(货品计量单位锁定等), 定义与启用状态逐条照搬。
DO $copy_triggers$
DECLARE
    v_trigger RECORD;
    v_definition TEXT;
BEGIN
    FOR v_trigger IN
        SELECT t.tgname, t.tgenabled, pg_get_triggerdef(t.oid) AS definition
        FROM pg_trigger t
        WHERE t.tgrelid = 'public.production_plan_costs_v648'::regclass
          AND NOT t.tgisinternal AND t.tgparentid = 0
          AND t.tgfoid <> 'public.fn_audit()'::regprocedure
        ORDER BY t.tgname
    LOOP
        v_definition := replace(v_trigger.definition,
            ' ON public.production_plan_costs_v648 ', ' ON public.production_plan_costs ');
        IF v_definition = v_trigger.definition THEN
            RAISE EXCEPTION 'V673 cannot retarget trigger %', v_trigger.tgname USING ERRCODE = '55000';
        END IF;
        EXECUTE v_definition;
        IF v_trigger.tgenabled = 'A' THEN
            EXECUTE format('ALTER TABLE public.production_plan_costs ENABLE ALWAYS TRIGGER %I', v_trigger.tgname);
        ELSIF v_trigger.tgenabled = 'R' THEN
            EXECUTE format('ALTER TABLE public.production_plan_costs ENABLE REPLICA TRIGGER %I', v_trigger.tgname);
        ELSIF v_trigger.tgenabled = 'D' THEN
            EXECUTE format('ALTER TABLE public.production_plan_costs DISABLE TRIGGER %I', v_trigger.tgname);
        END IF;
    END LOOP;
END;
$copy_triggers$;

-- 授权照搬(运行账号读取; 生产加固脚本另有统一授权)。
DO $copy_grants$
DECLARE
    v_grant RECORD;
BEGIN
    FOR v_grant IN
        SELECT r.rolname, acl.privilege_type
        FROM pg_class c
        CROSS JOIN LATERAL aclexplode(c.relacl) acl
        JOIN pg_roles r ON r.oid = acl.grantee
        WHERE c.oid = 'public.production_plan_costs_v648'::regclass
          AND acl.grantee <> c.relowner
    LOOP
        EXECUTE format('GRANT %s ON TABLE public.production_plan_costs TO %I',
                       v_grant.privilege_type, v_grant.rolname);
    END LOOP;
END;
$copy_grants$;

CREATE FUNCTION public.fn_guard_legacy_import_only() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
    IF current_setting('app.legacy_import', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION '老系统导入的历史数据只读, 只有遗留数据导入可以写入' USING ERRCODE = '42501';
    END IF;
    RETURN NULL;
END;
$$;
CREATE TRIGGER trg_guard_production_plan_costs_legacy_import_only
    BEFORE INSERT OR UPDATE OR DELETE ON public.production_plan_costs
    FOR EACH STATEMENT EXECUTE FUNCTION public.fn_guard_legacy_import_only();
ALTER TABLE public.production_plan_costs ENABLE ALWAYS TRIGGER trg_guard_production_plan_costs_legacy_import_only;

DROP TABLE public.production_plan_costs_v648;

-- 反查「哪些产品用到这个物料」: goods_id 等值 + 可选 bill_date 区间, 按 master_goods_id 聚合,
-- 所需列全部在索引里(仅索引扫描)。
CREATE INDEX idx_ppc_where_used_active ON public.production_plan_costs
    (goods_id, bill_date, master_goods_id, bill_item_id) INCLUDE (dqty, qty, pdraw_qty, owdraw_qty)
    WHERE is_deleted = FALSE AND node_class = 0 AND master_goods_id IS NOT NULL;
-- 外键检查与父子回填。
CREATE INDEX idx_ppc_goods ON public.production_plan_costs (goods_id);
CREATE INDEX idx_ppc_master_goods ON public.production_plan_costs (master_goods_id) WHERE master_goods_id IS NOT NULL;
CREATE INDEX idx_ppc_parent ON public.production_plan_costs (parent_id) WHERE parent_id IS NOT NULL;
