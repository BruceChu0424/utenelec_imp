package com.uten.imp.features.master.referencemethod;

import jakarta.validation.constraints.NotNull;

/**
 * 结算方式账期策略（settlement_method:edit；V453）。
 *
 * <p>约束镜像 V330 CHECK：termsBase/dueRule 枚举、defaultDueDays 0-3650、
 * fixedDayOfMonth 仅 FIXED_DAY_OF_MONTH 时必填（1-31）、monthsAhead 0-120。
 * 依赖未来事件（质检验收/对账确认/发票）的基准允许保存：到期日保持未定并等待
 * 专用事件处理器，不得猜日期（ADR-047）。
 *
 * @param name 可选新名称；null/空白表示不改名（引用一律走 UUID，改名安全）。
 */
public record SettlementMethodTermsRequest(
        String name,
        @NotNull String termsBase,
        @NotNull String dueRule,
        @NotNull Integer defaultDueDays,
        Integer fixedDayOfMonth,
        @NotNull Integer monthsAhead) {}
