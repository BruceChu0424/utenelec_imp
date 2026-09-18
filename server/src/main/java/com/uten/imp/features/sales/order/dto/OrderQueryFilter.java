package com.uten.imp.features.sales.order.dto;

import java.time.LocalDate;
import java.util.UUID;

/** 销售订货列表查询条件。chain=订单行链路状态组精确匹配（待发货大类 1/7/8 仍用）；
 *  chainGroup=数量派生大类（V545：pending 待生产=存在剩余未排量>0 的行 / production 生产中=存在未完工
 *  计划量>0 或 5/6 的行，与 stats 同口径）。sellerId=按销售员筛选（生产计划选来源单时按跟单员收敛）；
 *  currencyId=按币种筛选（2026-09-16 表头筛选；订单表无仓库列，warehouse 不在此列）。 */
public record OrderQueryFilter(
        String keyword,
        UUID clientId,
        Short status,
        Boolean closed,
        LocalDate dateFrom,
        LocalDate dateTo,
        java.util.List<Short> chain,
        UUID sellerId,
        String chainGroup,
        UUID currencyId) {

    /** 兼容旧调用（无 chainGroup/currencyId）。 */
    public OrderQueryFilter(
            String keyword, UUID clientId, Short status, Boolean closed,
            LocalDate dateFrom, LocalDate dateTo, java.util.List<Short> chain, UUID sellerId) {
        this(keyword, clientId, status, closed, dateFrom, dateTo, chain, sellerId, null, null);
    }

    /** 兼容旧调用（无 currencyId）。 */
    public OrderQueryFilter(
            String keyword, UUID clientId, Short status, Boolean closed,
            LocalDate dateFrom, LocalDate dateTo, java.util.List<Short> chain,
            UUID sellerId, String chainGroup) {
        this(keyword, clientId, status, closed, dateFrom, dateTo, chain, sellerId, chainGroup, null);
    }
}
