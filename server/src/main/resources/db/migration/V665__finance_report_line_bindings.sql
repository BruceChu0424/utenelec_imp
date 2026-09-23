-- V665 (ADR-112 / overhaul-gap-03): 总账附表与经营损益表的「报表行 → 取数来源」映射改为配置。
--
-- 原来报表按 Java 里写死的科目名(ps.name IN ('房租', ...))取数, 科目一改名就悄悄漏算;
-- 人工与折旧等没有科目名的行直接写 NULL。现在:
--   * STYLE 绑定: 报表行 → 具体科目(payment_styles.id)。科目改名不影响取数。
--     普通费用行取绑定科目的总账发生额; 折旧行取绑定费用科目上的固定资产折旧事实。
--   * DEPARTMENT 绑定: 人工行 → 部门(含下级部门), 取已审核工资单的应发合计。
--   * 某行没有任何绑定时, 报表明确显示「未配置科目」, 不再显示空值。
-- 行的清单与含义由代码定义(GlReportLine), 这里只存绑定。
-- 科目绑定只认费用类的末级科目: 取数只算绑定科目本身的发生额, 绑目录会漏算其下级;
-- 停用的科目仍可绑定, 用于统计它停用前的历史发生额。
CREATE TABLE finance_report_line_bindings (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    line_key      TEXT NOT NULL CHECK (line_key ~ '^[A-Z][A-Z0-9_]{1,63}$'),
    binding_kind  TEXT NOT NULL CHECK (binding_kind IN ('STYLE', 'DEPARTMENT')),
    style_id      UUID REFERENCES payment_styles(id) ON DELETE RESTRICT,
    department_id UUID REFERENCES departments(id) ON DELETE RESTRICT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by    UUID,
    CONSTRAINT finance_report_line_binding_target_chk CHECK (
        (binding_kind = 'STYLE' AND style_id IS NOT NULL AND department_id IS NULL)
        OR (binding_kind = 'DEPARTMENT' AND department_id IS NOT NULL AND style_id IS NULL)),
    CONSTRAINT finance_report_line_binding_style_uq UNIQUE (line_key, style_id),
    CONSTRAINT finance_report_line_binding_department_uq UNIQUE (line_key, department_id)
);
COMMENT ON TABLE finance_report_line_bindings IS
    'ADR-112 总账附表/经营损益表 报表行 → 科目(STYLE)或部门(DEPARTMENT)绑定; 无绑定的行在报表上标注未配置科目';
CREATE INDEX idx_finance_report_line_bindings_style ON finance_report_line_bindings(style_id)
    WHERE style_id IS NOT NULL;
CREATE INDEX idx_finance_report_line_bindings_department ON finance_report_line_bindings(department_id)
    WHERE department_id IS NOT NULL;

-- 收付款类别引用统一守卫(V265 协议): 写入前取类别层级锁, 再校验费用类 + 末级(不要求启用)。
CREATE TRIGGER trg_psref_finance_report_line_binding_style
    BEFORE INSERT OR UPDATE ON finance_report_line_bindings
    FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_style_reference(
        'style_id', 'EXPENSE', 'false', 'true', 'false', 'false');

-- 默认绑定(按原代码里的科目名, 同名科目全部绑定, 与原取数口径一致)做成可重复调用的函数:
-- 只补「还没有任何绑定」的行, 已有绑定的行不动; 只绑费用类末级科目。
-- 迁移执行时调用一次(已有科目的库直接生效); 新库在老库导入科目之后由 legacy bootstrap
-- (migrate_finance.sql)再调用一次, 财务也可在报表设置里点「按默认名单补齐」。人工/折旧行不猜, 保持未配置。
-- 报表行所在的表(与 GlReportLine.sheets() 同一划分)。
CREATE OR REPLACE FUNCTION fn_finance_report_line_sheet(p_line_key TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE STRICT
AS $$
    SELECT CASE
        WHEN p_line_key LIKE 'MFG\_%' THEN 'MANUFACTURING'
        WHEN p_line_key LIKE 'ADM\_%' THEN 'ADMIN'
        WHEN p_line_key IN ('PL_TAX', 'SALES_FEE', 'PL_FINANCE') THEN 'PROFIT'
        WHEN p_line_key LIKE 'OP\_%' THEN 'OPERATING'
        ELSE p_line_key
    END;
$$;

CREATE OR REPLACE FUNCTION fn_finance_report_line_bindings_seed_defaults()
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_inserted INTEGER;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended('uten:finance-report-line-bindings', 0));
    INSERT INTO finance_report_line_bindings(line_key, binding_kind, style_id)
    SELECT defaults.line_key, 'STYLE', style.id
    FROM (VALUES
        ('MFG_MOULD_REPAIR', '模具费用'), ('MFG_MOULD_REPAIR', '制作模具'),
        ('MFG_MATERIAL', '材料费用'), ('MFG_OTHER', '其它费用'),
        ('MFG_UTILITIES', '水费'), ('MFG_UTILITIES', '电费'),
        ('MFG_QC', '品质部'), ('MFG_QC', '品质部费用'),
        ('MFG_WAREHOUSE', '仓库费用'), ('MFG_ASSEMBLY', '安装车间费用'),
        ('MFG_INJECTION', '注塑部费用'), ('MFG_RAIL', '轨道车间费用'),
        ('MFG_COPPER', '铜粒车间费用'), ('MFG_PICKLING', '酸洗车间'),
        ('ADM_RENT', '房租'), ('ADM_SALARY', '工资费用'),
        ('ADM_MEAL', '餐费'), ('ADM_MEAL', '饭堂费用'),
        ('ADM_OFFICE', '办公费用'), ('ADM_PHONE', '电话费'), ('ADM_VEHICLE', '汽车费用'),
        ('ADM_CERT', '证书费用'), ('ADM_EXPRESS', '快递费用'), ('ADM_DESIGN', '设计费用'),
        ('ADM_LABOR_SUPPLY', '劳动用品'), ('ADM_HR', '人事部费用'), ('ADM_OTHER', '其它费用'),
        ('SALES_FEE', '销售费用'), ('SALES_FEE', '外贸部费用'), ('SALES_FEE', 'OEM部费用'),
        ('SALES_FEE', '运费'), ('SALES_FEE', '快递费用'), ('SALES_FEE', '淘宝网费用'),
        ('SALES_FEE', '慕朵费用'), ('SALES_FEE', '证书费用'),
        ('PL_TAX', '税金'), ('PL_FINANCE', '手续费'),
        ('OP_MEAL', '餐费'), ('OP_MEAL', '饭堂费用'),
        ('OP_RENT', '房租'), ('OP_ELECTRICITY', '电费'), ('OP_WATER', '水费'),
        ('OP_LOGISTICS', '运费'), ('OP_EXPRESS', '快递费用'), ('OP_OFFICE', '办公费用'),
        ('OP_PHONE', '电话费'), ('OP_DESIGN', '设计费用'), ('OP_TAX_FEE', '税金'),
        ('OP_FINANCE', '手续费'), ('OP_OTHER', '其它费用')
    ) AS defaults(line_key, style_name)
    JOIN payment_styles style ON style.name = defaults.style_name
        AND style.category = 'EXPENSE' AND COALESCE(style.is_deleted, FALSE) = FALSE
        AND NOT EXISTS (
            SELECT 1 FROM payment_styles child
            WHERE child.parent_id = style.id AND COALESCE(child.is_deleted, FALSE) = FALSE)
    WHERE NOT EXISTS (
        SELECT 1 FROM finance_report_line_bindings existing
        WHERE existing.line_key = defaults.line_key)
      -- 同一张表里一个科目只归一行(与服务端校验同口径): 该科目已归到同表另一行时不再补。
      -- 表按行键前缀区分: MFG_ 附12, ADM_ 附13, PL_TAX/SALES_FEE/PL_FINANCE 利润表, OP_ 附16。
      AND NOT EXISTS (
        SELECT 1 FROM finance_report_line_bindings existing
        WHERE existing.style_id = style.id
          AND fn_finance_report_line_sheet(existing.line_key) = fn_finance_report_line_sheet(defaults.line_key))
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    RETURN v_inserted;
END;
$$;

COMMENT ON FUNCTION fn_finance_report_line_bindings_seed_defaults() IS
    'ADR-112 按原科目名单为还没有任何绑定的报表行补默认绑定(只绑费用类末级科目), 返回新增条数';

SELECT fn_finance_report_line_bindings_seed_defaults();

CREATE TRIGGER trg_audit_finance_report_line_bindings
    AFTER INSERT OR UPDATE OR DELETE ON finance_report_line_bindings
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE finance_report_line_bindings
    ENABLE ALWAYS TRIGGER trg_audit_finance_report_line_bindings;

-- 清库策略: 报表配置随科目/部门主档保留(PRESERVE)。沿用 V617 的锚点补丁法, 锚点缺失即失败。
DO $reset_policy$
DECLARE definition TEXT; anchor TEXT := '(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V665 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition,anchor,anchor || E',\n            (''finance_report_line_bindings'', ''PRESERVE'')');
END;
$reset_policy$;
