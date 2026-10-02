package com.uten.imp.features.master.goods.costing;

import com.uten.imp.common.platformcolumns.DisplayPlatformColumnAdapter;
import com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter;
import com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter.FactDefinition;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import java.util.List;
import java.util.Set;

/** Cost display helpers have their own permission boundary and can never write authoritative costs. */
@Configuration
public class GoodsCostDisplayColumnsConfiguration {
    @Bean
    PlatformColumnResourceAdapter goodsCostDisplayColumns(SecurityContextCurrentUser current) {
        return new DisplayPlatformColumnAdapter("view_goods_cost", "货品成本辅助显示", Set.of("goods:cost:view"),
                Set.of("goods:cost:view"), current, List.of(
                new FactDefinition("designQty", "设计使用数量", false), new FactDefinition("actualQty", "真实使用数量", false),
                new FactDefinition("price", "导入单价", true), new FactDefinition("rate", "计价换算率", true),
                new FactDefinition("adoptedQty", "采用量", false), new FactDefinition("batchQty", "批次计价数量", false),
                new FactDefinition("perProductQty", "每产品用量", false), new FactDefinition("unitPrice", "采用单价", true),
                new FactDefinition("amount", "行成本", true), new FactDefinition("materialAmount", "材料金额", true),
                new FactDefinition("feeAmount", "本行费用", true), new FactDefinition("unitContribution", "单件成本贡献", true),
                new FactDefinition("value", "费用单价或费率", true), new FactDefinition("quantity", "费用数量或基数", false),
                new FactDefinition("baseAmount", "费用基数金额", true), new FactDefinition("unitAmount", "单位费用", true),
                new FactDefinition("knownAmountLocal", "已知实际金额", true), new FactDefinition("allocatedAmountLocal", "已分配金额", true),
                new FactDefinition("heldAmountLocal", "在制金额", true), new FactDefinition("amountLocal", "本币金额", true),
                new FactDefinition("netQtyBase", "净耗数量", false), new FactDefinition("grossQtyBase", "领入数量", false),
                new FactDefinition("returnedQtyBase", "退回数量", false), new FactDefinition("effectiveQtyBase", "有效产量", false),
                new FactDefinition("originalQtyBase", "原始产量", false), new FactDefinition("outputQtyBase", "所选产量", false),
                new FactDefinition("actualUnitCostLocal", "单位实际成本", true), new FactDefinition("knownTotal", "已知成本合计", true),
                new FactDefinition("unitCost", "单位测算成本", true)));
    }
}
