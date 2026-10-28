package com.uten.imp.features.payroll;

import com.uten.imp.common.web.ApiException;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Root;
import jakarta.persistence.criteria.Predicate;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Map;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class PayrollSlipHeaderQueryTest {
    @Test @SuppressWarnings("unchecked")
    void fieldsCompareBookedMoneyAndExactCalendarPeriodsWithoutRecomputingWages() {
        Root<PayrollSlip> root = mock(Root.class, RETURNS_DEEP_STUBS);
        CriteriaBuilder builder = mock(CriteriaBuilder.class);
        var headers = new PayrollSlipHeaderQuery("netIncome", "desc", Map.of(
                "search.grossIncome", ">=9007199254740993.0001", "search.period", "2026年10月", "search.publishedAt", "2026-10"));
        headers.apply(root, builder, new ArrayList<Predicate>());
        verify(builder).greaterThanOrEqualTo(root.<BigDecimal>get("grossIncome"), new BigDecimal("9007199254740993.0001"));
        verify(builder).equal(root.get("payrollYear"), (short)2026);
        verify(builder).equal(root.get("payrollMonth"), (short)10);
        verify(builder).greaterThanOrEqualTo(root.<Instant>get("publishedAt"), Instant.parse("2026-09-30T16:00:00Z"));
        verify(builder).lessThan(root.<Instant>get("publishedAt"), Instant.parse("2026-10-31T16:00:00Z"));
        assertThat(headers.sorting().getOrderFor("netIncome").isDescending()).isTrue();
        assertThat(headers.sorting().getOrderFor("id")).isNotNull();
    }
    @Test void unsupportedIdentityFieldsAndInvalidMoneyPeriodsFailClosed() {
        for (var filter : java.util.List.of(Map.of("search.employeeId", "other"), Map.of("search.netIncome", "NaN"),
                Map.of("search.period", "1999-10"), Map.of("search.period", "2026-13"), Map.of("search.publishedAt", "yesterday")))
            assertThatThrownBy(() -> new PayrollSlipHeaderQuery(null, null, filter)).isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> new PayrollSlipHeaderQuery("employeeId", "asc", Map.of())).isInstanceOf(ApiException.class);
    }
}
