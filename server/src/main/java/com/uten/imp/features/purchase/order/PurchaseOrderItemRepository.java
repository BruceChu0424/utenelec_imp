package com.uten.imp.features.purchase.order;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

/**
 * 采购订货明细仓库。「货品 → 最近一张订货单头条款」的学习查询 (findLastTermsPerGoods)
 * 已于 2026-09-16 退役: 预填一律读 goods / suppliers 主档默认列 (V593), 见
 * PurchaseOrderService#masterDefaultTermsPerGoods。
 */
public interface PurchaseOrderItemRepository extends JpaRepository<PurchaseOrderItem, UUID> {

    List<PurchaseOrderItem> findByOrderIdOrderByLineNoAsc(UUID orderId);

    @Modifying
    @Query("DELETE FROM PurchaseOrderItem i WHERE i.orderId = :oid")
    void deleteByOrderId(@Param("oid") UUID orderId);
}
