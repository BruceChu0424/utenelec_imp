package com.uten.imp.features.finance.report;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

class FinancePartySummaryTemplateTest {
    @Test void originalArOrderDoesNotHideCashVersusBookReconciliationOrTurnMissingAmountsIntoZero() {
        var row=new LinkedHashMap<String,Object>();row.put("prevBalance",new BigDecimal("100.1234"));row.put("shippedAmount",new BigDecimal("20"));row.put("returnAmount",new BigDecimal("-1"));row.put("receivedAmount",new BigDecimal("5"));row.put("offsetAmount",new BigDecimal("2"));row.put("balance",new BigDecimal("113.1234"));row.put("exchangeDiff",BigDecimal.ONE);row.put("arReductionAmount",new BigDecimal("6"));
        var result=FinancePartySummaryTemplate.present(true,source(row));
        assertThat(result.columns().stream().map(ReportColumn::label)).containsExactly("客户编号","客户简称","客户全称","业务员","总监","区域","所属地区","结算期限","铺底额","上月余额","发货金额","回款金额","退货金额","货款冲销","应收余额","超出铺底额","物料金额");
        assertThat(result.rows().getFirst().get("receivedAmount")).isEqualTo(new BigDecimal("5"));
        assertThat(result.rows().getFirst().get("__reconciliationDelta")).isEqualTo(BigDecimal.ONE.setScale(4));
        row.put("prevBalance",null);assertThat(FinancePartySummaryTemplate.present(true,source(row)).rows().getFirst().get("__reconciliationDelta")).isNull();
    }
    @Test void unknownGoodsToolingSplitCannotLeakLegacyAmountThroughAnExactTextCompanion() {
        var row=new LinkedHashMap<String,Object>();row.put("goodsAmount",new BigDecimal("123.4567"));row.put("goodsAmountExact","123.4567");row.put("prevBalance",BigDecimal.TEN);row.put("totalBalance",new BigDecimal("133.4567"));
        var result=FinancePartySummaryTemplate.present(false,source(row));assertThat(result.columns()).hasSize(15);
        var value=result.rows().getFirst();assertThat(value.get("goodsAmount")).isNull();assertThat(value).doesNotContainKey("goodsAmountExact");
        assertThat(value.get("__sourceGoodsAmount")).isEqualTo(new BigDecimal("123.4567"));assertThat(value.get("totalBalance")).isEqualTo(new BigDecimal("133.4567"));assertThat(value.get("__pending")).isEqualTo(true);
        assertThatThrownBy(()->FinancePartySummaryTemplate.requireOptions(false,new FinanceReportColumnOptions(Map.of("search.mouldAmount",">0"),null,null))).isInstanceOf(ApiException.class);
    }
    private static ReportTableResponse source(Map<String,Object> row){return new ReportTableResponse(List.of(),List.of(row),Map.of(),1,50,1,1);}
}
