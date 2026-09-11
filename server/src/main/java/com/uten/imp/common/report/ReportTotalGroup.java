package com.uten.imp.common.report;

import java.math.BigDecimal;

/**
 * 合计项的一个分组（单位 / 币种）。
 *
 * @param unit  分组名（单位名或币种名）；报表没有分组列时为 null，前端渲染成不带后缀的纯数值
 * @param value 该组的合计值
 */
public record ReportTotalGroup(String unit, BigDecimal value) {}
