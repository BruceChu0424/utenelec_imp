package com.uten.imp.features.finance.statement;

import com.uten.imp.features.org.employee.BusinessEmployeeReferencePurpose;
import org.junit.jupiter.api.Test;
import java.util.Set;
import static org.assertj.core.api.Assertions.assertThat;

class FinanceAuxiliaryPurposeTest {
    @Test void employeeReferenceRequiresTheWholeFinancialDirectoryOperationAndNeverAnHrGrant() {
        for(var purpose:Set.of(BusinessEmployeeReferencePurpose.FINANCE_AUXILIARY_PARTY,BusinessEmployeeReferencePurpose.FINANCE_EXPENSE_ATTRIBUTION)) {
        assertThat(purpose.mayListCandidates(Set.of("payment_style:edit","finance_report:view","finance:view:all"))).isTrue();
        for(var partial:Set.of(Set.of("payment_style:edit"),Set.of("finance_report:view","finance:view:all"),Set.of("employee:view"))) {
            assertThat(purpose.mayListCandidates(partial)).isFalse();assertThat(purpose.mayEcho(partial)).isFalse();
        }
        }
    }
}
