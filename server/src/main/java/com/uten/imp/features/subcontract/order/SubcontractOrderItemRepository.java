package com.uten.imp.features.subcontract.order;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

/**
 * 委外订货明细仓库。明细独立管理（不走主表 @OneToMany，规避软删+cascade 坑）。
 * 「货品 → 最近一张订货单头条款」的学习查询 (findLastTermsPerGoods) 已于 2026-09-16
 * 退役: 预填一律读 goods / suppliers 主档默认列 (V593), 见
 * SubcontractOrderService#masterDefaultTermsPerGoods。
 */
public interface SubcontractOrderItemRepository extends JpaRepository<SubcontractOrderItem, UUID> {

    @Query("SELECT i FROM SubcontractOrderItem i WHERE i.orderId=:orderId AND i.deleted=FALSE ORDER BY i.lineNo,i.id")
    List<SubcontractOrderItem> findByOrderIdOrderByLineNoAsc(@Param("orderId") UUID orderId);

    @Modifying
    @Query("DELETE FROM SubcontractOrderItem i WHERE i.orderId = :oid")
    void deleteByOrderId(@Param("oid") UUID orderId);
}
