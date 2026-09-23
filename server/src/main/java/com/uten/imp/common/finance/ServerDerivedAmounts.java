package com.uten.imp.common.finance;

import java.util.Set;

/**
 * 保存请求标记: 行金额与表头合计只由服务端按 {@link MoneyPolicy} 从数量 × 单价(× 折扣) × 汇率派生
 * (ADR-112)。实现此接口的请求 DTO 不声明金额字段; 请求体里出现 {@link #CLIENT_FORBIDDEN_FIELDS}
 * 中任一字段会被 {@link ServerDerivedAmountsModule} 拒绝为 400, 而不是被静默忽略。
 * 资金单据的「实际金额原文」(如付款/收款行的 amountOriginal)是银行事实, 由 DTO 显式声明, 不受此限;
 * 汇兑差额、税额、退货金额这类派生值同样只由服务端算, 请求里带了直接拒绝。
 */
public interface ServerDerivedAmounts {
    Set<String> CLIENT_FORBIDDEN_FIELDS = Set.of(
            "amountOriginal", "amountLocal", "totalOriginal", "totalLocal", "costAmount",
            "exchangeDiff", "taxAmount", "returnAmount");
}
