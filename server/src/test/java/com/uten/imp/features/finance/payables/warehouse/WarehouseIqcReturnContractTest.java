package com.uten.imp.features.finance.payables.warehouse;

import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts.RecordReturnRequest;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;

import java.lang.reflect.Method;
import java.lang.reflect.RecordComponent;
import java.util.Locale;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class WarehouseIqcReturnContractTest {

    private static final Set<String> PROHIBITED_FIELDS = Set.of(
            "price", "amount", "currency", "exchange", "tax", "settlement",
            "payable", "receivable", "credit", "offset", "nocredit", "finance",
            "ap", "replacement");
    private static final Set<String> PROHIBITED_COLUMNS = Set.of(
            "received_amount_original", "received_amount_local",
            "failed_amount_original", "failed_amount_local", "currency_id",
            "exchange_rate", "tax_rate", "settlement_method_id", "source_ap_ledger_id",
            "credit_source_id", "credit_ledger_id", "offset_id", "credit_reference",
            "closed_no_credit_reason", "finance_exception_code", "finance_exception_message");

    @Test
    void publicViewContainsOnlyPhysicalReturnFields() {
        assertThat(WarehouseIqcReturnView.class.isRecord()).isTrue();
        for (RecordComponent component : WarehouseIqcReturnView.class.getRecordComponents()) {
            String field = component.getName().toLowerCase(Locale.ROOT);
            assertThat(PROHIBITED_FIELDS)
                    .as(component.getName())
                    .noneMatch(field::contains);
        }
    }

    @Test
    void fixedProjectionSqlNeverSelectsCommercialOrFinanceColumns() {
        String sql = (WarehouseIqcReturnProjectionService.selectSql()
                + WarehouseIqcReturnProjectionService.fromSql()).toLowerCase(Locale.ROOT);
        assertThat(sql).contains(
                "procurement_iqc_rejection_cases",
                "procurement_inspection_items",
                "failed_base_qty",
                "failed_qty",
                "return_reference",
                "return_recorded_at");
        assertThat(PROHIBITED_COLUMNS).noneMatch(sql::contains);
        assertThat(sql).doesNotContain(
                "confirm_credit", "close_no_credit", "retry_finance_projection");
    }

    @Test
    void controllerSeparatesViewAndPhysicalActionAuthorities() throws Exception {
        RequestMapping root = WarehouseIqcReturnController.class
                .getAnnotation(RequestMapping.class);
        assertThat(root.value()).containsExactly("/api/warehouse/iqc-returns");

        Method list = WarehouseIqcReturnController.class.getDeclaredMethod(
                "list", String.class, String.class, String.class, int.class, int.class);
        Method detail = WarehouseIqcReturnController.class.getDeclaredMethod(
                "detail", UUID.class);
        Method action = WarehouseIqcReturnController.class.getDeclaredMethod(
                "recordReturn", UUID.class, RecordReturnRequest.class);
        assertThat(list.getAnnotation(GetMapping.class).value()).isEmpty();
        assertThat(detail.getAnnotation(GetMapping.class).value()).containsExactly("/{id}");
        assertThat(action.getAnnotation(PostMapping.class).value())
                .containsExactly("/{id}/record-return");
        assertThat(list.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('warehouse_iqc_return:view')");
        assertThat(detail.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('warehouse_iqc_return:view')");
        assertThat(action.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('warehouse_iqc_return:view')"
                        + " and hasAuthority('procurement_iqc_rejection:record_return')");
    }
}
