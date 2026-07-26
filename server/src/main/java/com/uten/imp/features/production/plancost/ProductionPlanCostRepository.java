package com.uten.imp.features.production.plancost;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.UUID;

/**
 * 生产计划成本 / BOM 展开仓储（只读 · 1.36M 行分区表）。
 *
 * <p>{@link JpaSpecificationExecutor} 支持按 bill_item_id / master_goods_id / bill_date 等条件分页查询。
 * <p><b>不提供</b> save/delete（本期只读保数据，design §3.5）。
 */
public interface ProductionPlanCostRepository
        extends JpaRepository<ProductionPlanCost, UUID>, JpaSpecificationExecutor<ProductionPlanCost> {
}
