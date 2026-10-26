package com.uten.imp.common.report;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.TestFactory;

import java.lang.reflect.InvocationTargetException;
import java.util.List;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ReportBooleanFacetDomainsTest {
    @TestFactory Stream<DynamicTest> everyDomainPreservesNullBucketsAndRejectsMalformedBooleans() {
        return Stream.of("sales", "purchase", "subcontract", "production", "stock", "finance")
                .map(domain -> DynamicTest.dynamicTest(domain, () -> {
                    String name = "com.uten.imp.features." + domain + ".report."
                            + Character.toUpperCase(domain.charAt(0)) + domain.substring(1) + "ReportService";
                    var method = Class.forName(name).getDeclaredMethod("facetClause", ReportQueryKit.FacetSpec.class, String.class);
                    method.setAccessible(true);
                    var spec = new ReportQueryKit.FacetSpec("approved", "o.approved AS v,o.approved AS lbl",
                            "o.approved", "o.approved", "bool");
                    var yes = (ReportQueryKit.WhereBuilder.Clause) method.invoke(null, spec, "true");
                    var no = (ReportQueryKit.WhereBuilder.Clause) method.invoke(null, spec, "FALSE");
                    assertThat(yes.val()).isEqualTo(true);assertThat(no.val()).isEqualTo(false);
                    var empty = (ReportQueryKit.WhereBuilder.Clause) method.invoke(null, spec, "__null__");
                    assertThat(empty.fragment()).contains("IS NULL");assertThat(empty.val()).isNull();
                    for (String value : List.of("yes", "1", "0", "false,true")) {
                        assertThatThrownBy(() -> method.invoke(null, spec, value))
                                .isInstanceOfSatisfying(InvocationTargetException.class, failure ->
                                        assertThat(failure.getCause()).isInstanceOfSatisfying(ApiException.class,
                                                invalid -> assertThat(invalid.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED)));
                    }
                }));
    }
}
