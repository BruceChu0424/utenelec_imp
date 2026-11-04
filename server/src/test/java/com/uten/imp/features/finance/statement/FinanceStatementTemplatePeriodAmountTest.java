package com.uten.imp.features.finance.statement;

import com.uten.imp.common.report.*;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

class FinanceStatementTemplatePeriodAmountTest {
    @Test void materialD41UsesTheWholeJProcessingTotalAndNeverTheAdjustedOrClosingAmount(){
        var totals=List.of(total("processAmount","100.123456789012345678901234"),total("amount","113"),total("balance","9999"));
        assertThat(FinanceStatementTemplate.periodAmount("otherReceivableStatement",totals,12)).isEqualByComparingTo("100.123456789012345678901234");
    }
    @Test void subcontractKeepsTheActualMaterialDeductionAndSupplierUsesItsOwnAmount(){
        var totals=List.of(total("processAmount","100"),total("materialAmount","0.000000000000000000000001"),total("amount","113"));
        assertThat(FinanceStatementTemplate.periodAmount("subcontractStatement",totals,1)).isEqualByComparingTo("99.999999999999999999999999");
        assertThat(FinanceStatementTemplate.periodAmount("supplierStatement",totals,1)).isEqualByComparingTo("113");
    }
    @Test void missingOrMixedGroupsCannotBecomeKnownZero(){
        assertThat(FinanceStatementTemplate.periodAmount("otherReceivableStatement",List.of(total("amount","100")),1)).isNull();
        var mixed=new ReportTotal("processAmount","工费","money","unit",List.of(new ReportTotalGroup("USD",BigDecimal.ONE,"usd"),new ReportTotalGroup("CNY",BigDecimal.ONE,"cny")));
        assertThat(FinanceStatementTemplate.periodAmount("otherReceivableStatement",List.of(mixed),2)).isNull();
        assertThat(FinanceStatementTemplate.periodAmount("otherReceivableStatement",List.of(),0)).isZero();
    }
    private static ReportTotal total(String key,String value){return new ReportTotal(key,key,"money",null,List.of(new ReportTotalGroup(null,new BigDecimal(value))));}
}
