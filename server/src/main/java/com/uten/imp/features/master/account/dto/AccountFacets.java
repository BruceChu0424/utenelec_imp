package com.uten.imp.features.master.account.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.List;
import java.util.Map;

/**
 * 账户 facet 结果：各筛选字段（类型/状态/币种）的 distinct 值桶 + 各字段空值计数。
 *
 * <p>金额字段（init/receipts/payments/balance）不进 facet，仅列表/详情展示。
 */
@Getter
@AllArgsConstructor
public class AccountFacets {
    private final List<FacetBucket> accountType;
    private final List<FacetBucket> status;
    private final List<FacetBucket> currencyId;
    private final Map<String, Long> nullCounts;
}
