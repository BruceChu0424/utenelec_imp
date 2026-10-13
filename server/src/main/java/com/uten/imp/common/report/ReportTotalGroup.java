package com.uten.imp.common.report;

import java.math.BigDecimal;

/**
 * 合计项的一个分组（单位 / 币种）。
 *
 * @param unit  分组名（单位名或币种名）；报表没有分组列时为 null，前端渲染成不带后缀的纯数值
 * @param value 该组的合计值；有分组维度但 unit 未维护时为 null，表示合计待核验，不合并未知币种/单位
 * @param identity 真实币种/单位身份；名称相同仍保持独立。旧无分组构造可为空；分组身份缺失时 value 为 null
 */
public record ReportTotalGroup(String unit, BigDecimal value, String identity) {
    public ReportTotalGroup(String unit,BigDecimal value) { this(unit,value,null); }
    public String getValueExact() { return com.uten.imp.common.util.DecimalText.of(value); }
}
