package com.uten.imp.features.finance.gl;

import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

class FinancialStatementAnnualTest {
    @Test void originalFifteenHeadersAndAnnualRatioUseTheSameMonthlyFacts() {
        assertThat(FinancialStatementAnnual.columns(2026)).extracting(c->c.label().replaceAll("\\s+",""))
                .containsExactly("项目","01月金额","02月金额","03月金额","04月金额","05月金额","06月金额",
                        "07月金额","08月金额","09月金额","10月金额","11月金额","12月金额","2026年全年合计","月均利润率");
        var revenue=row(1,"1000");var net=row(32,"-18");
        FinancialStatementAnnual.totals(List.of(revenue,net));
        assertThat((BigDecimal)revenue.get("yearTotal")).isEqualByComparingTo("12000");
        assertThat((BigDecimal)net.get("yearTotal")).isEqualByComparingTo("-216");
        assertThat((BigDecimal)net.get("profitRatio")).isEqualByComparingTo("-1.8");
    }
    @Test void missingMonthsAndZeroRevenueNeverBecomeHealthyZeroPercent() {
        var revenue=row(1,"0");var net=row(32,"100");net.put("m7",null);
        FinancialStatementAnnual.totals(List.of(revenue,net));
        assertThat(net).containsEntry("yearTotal",null).containsEntry("profitRatio",null);
        net.put("m7",BigDecimal.ZERO);FinancialStatementAnnual.totals(List.of(revenue,net));
        assertThat(net.get("yearTotal")).isNotNull();assertThat(net.get("profitRatio")).isNull();
    }
    @Test void futureMonthsStayBlankAndDoNotInvalidateTheVerifiedSelectedMonths() {
        var revenue=row(1,"100");var net=row(32,"20");
        for(int month=10;month<=12;month++){revenue.remove("m"+month);net.remove("m"+month);}
        FinancialStatementAnnual.totals(List.of(revenue,net),9);
        assertThat((BigDecimal)revenue.get("yearTotal")).isEqualByComparingTo("900");
        assertThat((BigDecimal)net.get("yearTotal")).isEqualByComparingTo("180");
        assertThat((BigDecimal)net.get("profitRatio")).isEqualByComparingTo("20");
        revenue.put("m3",null);FinancialStatementAnnual.totals(List.of(revenue,net),9);
        assertThat(revenue.get("yearTotal")).isNull();assertThat(net.get("profitRatio")).isNull();
    }
    private static Map<String,Object> row(int no,String amount) {
        Map<String,Object> row=new LinkedHashMap<>();row.put("lineNo",no);
        for(int month=1;month<=12;month++)row.put("m"+month,new BigDecimal(amount));return row;
    }
}
