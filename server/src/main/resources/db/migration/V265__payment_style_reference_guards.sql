-- =====================================================================
-- 收付款类别引用一致性守卫
--
-- 统一协议：
--   1. payment_styles 的层级/状态维护先取得 PAYMENT_STYLE_HIERARCHY 事务锁；
--   2. 任何新建或改写 payment_styles 引用的 SQL，也必须先取得同一把锁；
--   3. 加锁后重新校验类别、启用状态与“无任何未软删子项”的叶子语义。
--
-- Java 服务会在业务行锁之前主动取得该锁，以便尽早给出领域错误；本迁移的
-- BEFORE 触发器是数据库最终防线，覆盖原生 SQL、批处理和未来遗漏的写入口。
-- =====================================================================

CREATE OR REPLACE FUNCTION fn_guard_payment_style_reference()
RETURNS TRIGGER AS $$
DECLARE
    v_column          TEXT := TG_ARGV[0];
    v_expected        TEXT := NULLIF(TG_ARGV[1], '');
    v_require_active  BOOLEAN := COALESCE(NULLIF(TG_ARGV[2], '')::BOOLEAN, FALSE);
    v_require_leaf    BOOLEAN := COALESCE(NULLIF(TG_ARGV[3], '')::BOOLEAN, FALSE);
    v_legacy_lookup   BOOLEAN := COALESCE(NULLIF(TG_ARGV[4], '')::BOOLEAN, FALSE);
    v_force_check     BOOLEAN := COALESCE(NULLIF(TG_ARGV[5], '')::BOOLEAN, FALSE);
    v_new_value       TEXT;
    v_old_value       TEXT;
    v_style_id        UUID;
    v_category        TEXT;
    v_status          TEXT;
BEGIN
    v_new_value := to_jsonb(NEW) ->> v_column;
    IF v_new_value IS NULL OR btrim(v_new_value) = '' THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'UPDATE' AND NOT v_force_check THEN
        v_old_value := to_jsonb(OLD) ->> v_column;
        IF v_new_value IS NOT DISTINCT FROM v_old_value THEN
            RETURN NEW;
        END IF;
    END IF;

    -- Transaction-scoped and re-entrant for the current transaction.
    PERFORM pg_advisory_xact_lock(hashtextextended('PAYMENT_STYLE_HIERARCHY', 0));

    -- The offline legacy finance bootstrap loads accounts before payment_styles.
    -- It uses this transaction-local, narrowly named mode and performs an explicit
    -- existence/category reconciliation before commit. Runtime code never sets it.
    IF current_setting('uten.payment_style_reference_import', TRUE)
            = 'legacy-finance-v1' THEN
        RETURN NEW;
    END IF;

    IF v_legacy_lookup THEN
        SELECT style.id, style.category, style.status
          INTO v_style_id, v_category, v_status
          FROM payment_styles style
         WHERE style.legacy_id = v_new_value::INTEGER
           AND COALESCE(style.is_deleted, FALSE) = FALSE;
    ELSE
        SELECT style.id, style.category, style.status
          INTO v_style_id, v_category, v_status
          FROM payment_styles style
         WHERE style.id = v_new_value::UUID
           AND COALESCE(style.is_deleted, FALSE) = FALSE;
    END IF;

    IF v_style_id IS NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = '23503',
            MESSAGE = format(
                '收付款类别引用无效：%I.%I=%s 不存在或已删除',
                TG_TABLE_NAME, v_column, v_new_value);
    END IF;

    IF v_expected IS NOT NULL AND v_category IS DISTINCT FROM v_expected THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = format(
                '收付款类别引用无效：%I.%I 需要 %s 类别，实际为 %s',
                TG_TABLE_NAME, v_column, v_expected, v_category);
    END IF;

    IF v_require_active AND v_status IS DISTINCT FROM '使用' THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = format(
                '收付款类别引用无效：%I.%I 只能引用使用中的类别',
                TG_TABLE_NAME, v_column);
    END IF;

    IF v_require_leaf AND EXISTS (
        SELECT 1
          FROM payment_styles child
         WHERE child.parent_id = v_style_id
           AND COALESCE(child.is_deleted, FALSE) = FALSE
    ) THEN
        RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = format(
                '收付款类别引用无效：%I.%I 只能引用无子类别的叶子节点',
                TG_TABLE_NAME, v_column);
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Changed-reference guards. Arguments:
-- trigger name, table, column, expected category, active?, leaf?, legacy lookup?
DO $$
DECLARE
    spec RECORD;
BEGIN
    FOR spec IN
        SELECT * FROM (VALUES
            ('trg_psref_accounts_style',       'accounts',                           'style_legacy_id',              'ACCOUNT', TRUE,  TRUE,  TRUE),
            ('trg_psref_receipt_other_fee',    'finance_receipts',                   'other_fee_style_id',           'EXPENSE', TRUE,  TRUE,  FALSE),
            ('trg_psref_expense_item',         'finance_expense_items',              'expense_style_id',             'EXPENSE', TRUE,  TRUE,  FALSE),
            ('trg_psref_income_item',          'finance_other_income_items',         'income_style_id',              'INCOME',  TRUE,  TRUE,  FALSE),
            ('trg_psref_claim_payment',        'expense_claims',                     'payment_expense_style_id',     'EXPENSE', TRUE,  TRUE,  FALSE),

            ('trg_psref_fixed_expense',        'fixed_assets',                       'expense_style_id',             'EXPENSE', TRUE,  TRUE,  FALSE),
            ('trg_psref_fixed_cost_snap',      'fixed_assets',                       'cost_style_snapshot_id',       'ACCOUNT', FALSE, TRUE,  FALSE),
            ('trg_psref_fixed_accum_snap',     'fixed_assets',                       'accumulated_style_snapshot_id','ACCOUNT', FALSE, TRUE,  FALSE),
            ('trg_psref_fixed_exp_snap',       'fixed_assets',                       'expense_style_snapshot_id',    'EXPENSE', FALSE, TRUE,  FALSE),
            ('trg_psref_fixed_clear_snap',     'fixed_assets',                       'clearing_style_snapshot_id',   'ACCOUNT', FALSE, TRUE,  FALSE),

            ('trg_psref_deferred_expense',     'deferred_expenses',                  'expense_style_id',             'EXPENSE', TRUE,  TRUE,  FALSE),
            ('trg_psref_deferred_cost_snap',   'deferred_expenses',                  'cost_style_snapshot_id',       'ACCOUNT', FALSE, TRUE,  FALSE),
            ('trg_psref_deferred_accum_snap',  'deferred_expenses',                  'accumulated_style_snapshot_id','ACCOUNT', FALSE, TRUE,  FALSE),
            ('trg_psref_deferred_exp_snap',    'deferred_expenses',                  'expense_style_snapshot_id',    'EXPENSE', FALSE, TRUE,  FALSE),
            ('trg_psref_deferred_clear_snap',  'deferred_expenses',                  'clearing_style_snapshot_id',   'ACCOUNT', FALSE, TRUE,  FALSE),

            -- Draft policies may point at a disabled leaf while being prepared;
            -- activation is guarded separately below and requires active leaves.
            ('trg_psref_asset_cat_cost',       'finance_asset_categories',           'cost_style_id',                'ACCOUNT', FALSE, TRUE,  FALSE),
            ('trg_psref_asset_cat_accum',      'finance_asset_categories',           'accumulated_style_id',         'ACCOUNT', FALSE, TRUE,  FALSE),
            ('trg_psref_asset_cat_expense',    'finance_asset_categories',           'expense_style_id',             'EXPENSE', FALSE, TRUE,  FALSE),
            ('trg_psref_asset_cat_clearing',   'finance_asset_categories',           'clearing_style_id',            'ACCOUNT', FALSE, TRUE,  FALSE),

            -- Snapshot/book/schedule columns are frozen historical identities.
            -- Their service entry points validate active leaves before first
            -- creation, while the DB guard keeps category+leaf stable and lets a
            -- later controlled reversal reuse a now-disabled historical style.
            ('trg_psref_asset_book_cost',      'finance_asset_books',                'cost_style_id',                'ACCOUNT', FALSE, TRUE,  FALSE),
            ('trg_psref_asset_book_accum',     'finance_asset_books',                'accumulated_style_id',         'ACCOUNT', FALSE, TRUE,  FALSE),
            ('trg_psref_asset_book_expense',   'finance_asset_books',                'expense_style_id',             'EXPENSE', FALSE, TRUE,  FALSE),
            ('trg_psref_asset_book_clearing',  'finance_asset_books',                'clearing_style_id',            'ACCOUNT', FALSE, TRUE,  FALSE),

            ('trg_psref_def_sched_expense',    'finance_deferral_schedule_versions', 'expense_style_id',             'EXPENSE', FALSE, TRUE,  FALSE),
            ('trg_psref_def_sched_cost',       'finance_deferral_schedule_versions', 'cost_style_id',                'ACCOUNT', FALSE, TRUE,  FALSE),
            ('trg_psref_def_sched_clearing',   'finance_deferral_schedule_versions', 'clearing_style_id',            'ACCOUNT', FALSE, TRUE,  FALSE),

            -- Frozen posting lines and GL rows must also take the lock, but reversals
            -- are allowed to reuse a category that was disabled after original posting.
            ('trg_psref_post_line_cost',       'finance_asset_posting_lines',        'cost_style_id',                '',        FALSE, FALSE, FALSE),
            ('trg_psref_post_line_accum',      'finance_asset_posting_lines',        'accumulated_style_id',         '',        FALSE, FALSE, FALSE),
            ('trg_psref_post_line_expense',    'finance_asset_posting_lines',        'expense_style_id',             '',        FALSE, FALSE, FALSE),
            ('trg_psref_post_line_clearing',   'finance_asset_posting_lines',        'clearing_style_id',            '',        FALSE, FALSE, FALSE),
            ('trg_psref_gl_entry_style',       'gl_entries',                         'style_id',                     '',        FALSE, FALSE, FALSE)
        ) AS guards(trigger_name, table_name, column_name, expected_category,
                    require_active, require_leaf, legacy_lookup)
    LOOP
        EXECUTE format(
            'CREATE TRIGGER %I BEFORE INSERT OR UPDATE ON %I '
            'FOR EACH ROW EXECUTE FUNCTION fn_guard_payment_style_reference(%L,%L,%L,%L,%L,%L)',
            spec.trigger_name,
            spec.table_name,
            spec.column_name,
            spec.expected_category,
            spec.require_active,
            spec.require_leaf,
            spec.legacy_lookup,
            FALSE);
    END LOOP;
END;
$$;

-- An asset policy's style ids do not change during DRAFT -> ACTIVE. Force a
-- post-lock revalidation for both direct INSERT ACTIVE and activation UPDATE.
DO $$
DECLARE
    spec RECORD;
    event_sql TEXT;
BEGIN
    FOR spec IN
        SELECT * FROM (VALUES
            ('cost_style_id',         'ACCOUNT'),
            ('accumulated_style_id',  'ACCOUNT'),
            ('expense_style_id',      'EXPENSE'),
            ('clearing_style_id',     'ACCOUNT')
        ) AS styles(column_name, expected_category)
    LOOP
        event_sql := format(
            'CREATE TRIGGER %I BEFORE INSERT ON finance_asset_categories '
            'FOR EACH ROW WHEN (NEW.status = ''ACTIVE'') '
            'EXECUTE FUNCTION fn_guard_payment_style_reference(%L,%L,%L,%L,%L,%L)',
            'trg_psref_asset_cat_active_ins_' || spec.column_name,
            spec.column_name, spec.expected_category, TRUE, TRUE, FALSE, TRUE);
        EXECUTE event_sql;

        event_sql := format(
            'CREATE TRIGGER %I BEFORE UPDATE OF status ON finance_asset_categories '
            'FOR EACH ROW WHEN (NEW.status = ''ACTIVE'' AND OLD.status IS DISTINCT FROM NEW.status) '
            'EXECUTE FUNCTION fn_guard_payment_style_reference(%L,%L,%L,%L,%L,%L)',
            'trg_psref_asset_cat_active_upd_' || spec.column_name,
            spec.column_name, spec.expected_category, TRUE, TRUE, FALSE, TRUE);
        EXECUTE event_sql;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION fn_guard_payment_style_reference() IS
    'Serializes payment_styles hierarchy changes with new business references and validates category/status/leaf semantics after locking.';
