-- V461: 恢复 V458 意外丢失的 SUBCONTRACT_PREPARATION 来源类型。
-- V458 重写 production_material_analysis_item_source_type_chk 时基于 V234 的
-- 基线清单，漏带了 V436 增补的 'SUBCONTRACT_PREPARATION'（委外目标出仓备料
-- 目标行）。委外备料链路（SubcontractPreparationCoordinator /
-- SubcontractPreparationEntitlementHandoffService 等 7 个服务仍在写该类型）
-- 在 V458+ 真库上 INSERT 即被 production_material_analysis_item_source_type_chk
-- 以 23514 拒绝；SubcontractPreparationEntitlementHandoffMigrationPostgresTest
-- 的 fixture 播种先行触发。本迁移仅恢复该枚举值，其余清单与 V458 完全一致，
-- 不加表、不放宽 parent 形状约束。

ALTER TABLE production_material_analysis_items
    DROP CONSTRAINT production_material_analysis_item_source_type_chk,
    ADD CONSTRAINT production_material_analysis_item_source_type_chk CHECK (
        source_type IN (
            'SALES_ORDER_ITEM', 'REWORK', 'TRIAL', 'SAMPLE',
            'STOCK', 'OTHER', 'MAKE_COMPONENT', 'SUBCONTRACT_MAKE',
            'SUBCONTRACT_PREPARATION'
        )
    );
