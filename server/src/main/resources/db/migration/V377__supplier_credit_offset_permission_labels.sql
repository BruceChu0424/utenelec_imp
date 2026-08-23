-- V377: prepayments are deliberately not supported by the generic supplier-credit
-- offset command. Keep permission labels aligned with the fail-closed runtime.

UPDATE permissions
SET name = '应用供应商贷项',
    description = '把已确认采购退货贷项或供应商索赔贷项逐笔应用到同供应商、同币种、同开账汇率正应付；供应商预付款资产应用尚未开放'
WHERE code = 'supplier_open_item_offset:apply';

UPDATE permissions
SET name = '反转供应商贷项应用',
    description = '按应用批次对称恢复供应商贷项与应付余额并保留历史记录'
WHERE code = 'supplier_open_item_offset:reverse';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM permissions
        WHERE code = 'supplier_open_item_offset:apply'
          AND name = '应用供应商贷项'
          AND description NOT LIKE '%预付款逐笔应用%'
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
            MESSAGE = 'supplier credit offset permission labels are not aligned with runtime capability';
    END IF;
END $$;
