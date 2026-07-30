-- 固定资产与长期待摊管理列表的稳定分页索引。
CREATE INDEX IF NOT EXISTS idx_fixed_assets_code_active
    ON fixed_assets(code, id)
    WHERE is_deleted = FALSE;

CREATE INDEX IF NOT EXISTS idx_deferred_expenses_code_active
    ON deferred_expenses(code, id)
    WHERE is_deleted = FALSE;
