package com.uten.imp.features.finance.payables;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import static org.assertj.core.api.Assertions.*;

class ProcurementIqcRejectionHeaderQueryTest {
    @Test void amountCriteriaAreDeniedBeforeParsingWhenTheAmountIsMasked() {
        for(var query:List.of(Map.of("search.amount","NaN"),Map.of("search.amount",">=25"),
                Map.of("sort","amount","order","desc")))
            assertThatThrownBy(()->ProcurementIqcRejectionColumnQuery.read(query,false))
                    .isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.FORBIDDEN));
    }
    @Test void quantitiesAndLocalMoneyRemainExactAndRequestTextCannotBecomeSql() {
        var read=ProcurementIqcRejectionColumnQuery.read(Map.of("search.amount",">=90071992547409.1234",
                "search.failedQty","0.0001..2.5001","search.goodsName","螺丝_%","sort","amount","order","desc"),true);
        assertThat(read.criteria().predicate()).contains("rejection.failed_qty","rejection.failed_amount_local","goods.name")
                .doesNotContain("failed_amount_original","螺丝_%","90071992547409");
        assertThat(read.criteria().parameters().values()).contains(new BigDecimal("90071992547409.1234"),
                new BigDecimal("0.0001"),new BigDecimal("2.5001"));
        assertThat(read.orderBy()).startsWith("rejection.failed_amount_local DESC NULLS LAST");
        assertThatThrownBy(()->ProcurementIqcRejectionColumnQuery.read(Map.of("search.ownerUserId","other"),true))
                .isInstanceOf(ApiException.class);
    }
    @Test void displayReasonKeepsTheVisibleMessagePrecedenceAndCalendarIndependentNextStep() {
        assertThat(ProcurementIqcRejectionColumnQuery.displayReason("FINANCE_EXCEPTION","  编码待修复  ","fallback"))
                .isEqualTo("编码待修复");
        assertThat(ProcurementIqcRejectionColumnQuery.displayReason("PENDING_RETURN","  ","未闭环"))
                .isEqualTo("未闭环");
        assertThat(ProcurementIqcRejectionColumnQuery.displayReason("FINANCE_EXCEPTION",null,null))
                .isEqualTo("下一步：修复后重试财务投影");
        assertThat(ProcurementIqcRejectionColumnQuery.displayReason("CREDIT_CONFIRMED",null,null))
                .isEqualTo("供应商贷项已闭环");
    }
}
