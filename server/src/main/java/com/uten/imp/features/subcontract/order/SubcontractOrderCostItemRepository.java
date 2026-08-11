package com.uten.imp.features.subcontract.order;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.UUID;

/**
 * 委外订货 BOM 成本子表仓库 —— <b>只读</b>（design doc 22 §五：本期不实现自动展开，
 * 仅保结构 + 迁老库 67 行原样数据）。新系统不写本表及其累计字段。
 */
public interface SubcontractOrderCostItemRepository extends JpaRepository<SubcontractOrderCostItem, UUID> {

    /** 按订货单查 BOM 成本子表（树状展示按 bom_level 排序）。 */
    List<SubcontractOrderCostItem> findByOrderIdOrderByBomLevelAsc(UUID orderId);

    /** 按根成品订货明细查直接子件。 */
    List<SubcontractOrderCostItem> findByOrderItemIdOrderByBomLevelAsc(UUID orderItemId);
}
