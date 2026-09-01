package com.uten.imp.features.master.referencemethod;

import java.util.UUID;

/**
 * 结算方式管理页列表行（settlement_method:view；含禁用行与账期策略）。
 *
 * <p>systemRole 非空（CASH/MONTHLY）时前端展示「系统角色·锁定」，账期不可在线改。
 */
public record SettlementMethodAdminItem(
        UUID id,
        Integer legacyId,
        String code,
        String name,
        String status,
        String systemRole,
        String termsBase,
        String dueRule,
        Integer defaultDueDays,
        Integer fixedDayOfMonth,
        Integer monthsAhead,
        Integer sortOrder,
        String remark) {}
