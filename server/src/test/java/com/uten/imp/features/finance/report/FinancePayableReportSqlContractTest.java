package com.uten.imp.features.finance.report;

import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.finance.asset.FixedAssetService;
import com.uten.imp.features.finance.cost.FinanceCostService;
import com.uten.imp.features.finance.gl.GlReportService;
import com.uten.imp.features.finance.statement.FinanceStatementService;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class FinancePayableReportSqlContractTest {

    @Test
    void payableDetailUsesAuthoritativeDualCurrencyPaymentOffsetAndBalanceFields() {
        Fixture fixture = fixture();

        ReportTableResponse response = fixture.service().arApDetail(
                "AP", null, null, null, null, null, null,
                Map.of(), 1, 50, null, null);

        assertThat(response.columns()).extracting(ReportColumn::key)
                .contains("receivedOriginal", "offsetOriginal", "balanceOriginal", "offsetLocal");
        assertThat(fixture.sql())
                .contains("l.amount_received_original AS \"receivedOriginal\"")
                .contains("l.amount_offset_original AS \"offsetOriginal\"")
                .contains("l.amount_balance_original AS \"balanceOriginal\"")
                .contains("l.amount_received_local AS \"receivedLocal\"")
                .doesNotContain("CASE WHEN l.direction='AR' THEN l.amount_received_original ELSE NULL END");
    }

    @Test
    void payableSummaryIsAsOfDatedAndSeparatesPurchaseSubcontractCreditsPaymentsAndOffsets() {
        Fixture fixture = fixture();

        ReportTableResponse response = fixture.service().payableSummary(
                null, LocalDate.of(2026, 7, 1), LocalDate.of(2026, 7, 31),
                Map.of(), 1, 50, null, null);

        assertThat(response.columns()).extracting(ReportColumn::key)
                .contains("goodsAmount", "subcontractAmount", "purchaseReturnAmount",
                        "subcontractReturnAmount", "wasteDeductionAmount", "claimOffsetAmount",
                        "reversedAmount", "paidAmount", "settledAmount", "exchangeDifferenceLocal",
                        "offsetAmount", "creditReleasedAmount", "balance");
        assertThat(fixture.sql())
                .contains("source_doc_type='PURCHASE_RECEIPT'")
                .contains("source_doc_type='SUBCONTRACT_RECEIPT'")
                .contains("source_doc_type IN('PURCHASE_RETURN','PURCHASE_IQC_CREDIT')")
                .contains("source_doc_type IN('SUBCONTRACT_RETURN','SUBCONTRACT_IQC_CREDIT')")
                .contains("'PURCHASE_IQC_CREDIT'")
                .contains("'SUBCONTRACT_IQC_CREDIT'")
                .contains("source_doc_type='SUBCONTRACT_WASTE'")
                .contains("source_doc_type='SUBCONTRACT_LOSS_OFFSET'")
                .contains("WITH ledger_events AS")
                .contains("'REVERSE' AS event_type")
                .contains("(ledger.deleted_at AT TIME ZONE 'Asia/Shanghai')::date <= :to")
                .contains("COALESCE(payment.reversed_at, payment.updated_at)")
                .contains("AT TIME ZONE 'Asia/Shanghai')::date AS reverse_date")
                .contains("payment_events AS")
                .contains("'PAYMENT_REVERSE'")
                .contains("offset_events AS")
                .contains("'OFFSET_REVERSE'")
                .contains("payment.bill_date <= :to")
                .contains("line.applied_amount_local")
                .contains("FROM supplier_open_item_offsets offset_row")
                .contains("offset_row.effective_date <= :to")
                .contains("(offset_row.reversed_at AT TIME ZONE 'Asia/Shanghai')::date <= :to")
                .doesNotContain("ledger.deleted_at::date")
                .doesNotContain("payment.updated_at::date")
                .doesNotContain("offset_row.reversed_at::date")
                .doesNotContain("SUM(payment.amount_local) AS total_paid")
                .doesNotContain("COALESCE(pa.period_paid,0) AS \"offsetAmount\"");
    }

    private static Fixture fixture() {
        EntityManager em = mock(EntityManager.class);
        List<String> sql = new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            sql.add(invocation.getArgument(0));
            Query query = mock(Query.class);
            when(query.setParameter(anyString(), any())).thenReturn(query);
            when(query.getResultList()).thenReturn(List.of());
            when(query.getSingleResult()).thenReturn(0L);
            return query;
        });
        FinanceDocumentAccessPolicy access = mock(FinanceDocumentAccessPolicy.class);
        OwnerScope scope = new OwnerScope(true, Set.of());
        when(access.scope()).thenReturn(scope);
        when(access.nativeReadScope(anyString(), anyString(), eq(scope)))
                .thenReturn(new NativeReadScope("1=1", null, Set.of()));
        return new Fixture(new FinanceReportService(
                em,
                access,
                mock(SystemSettingsService.class),
                mock(FinanceStatementService.class),
                mock(FinanceCostService.class),
                mock(GlReportService.class),
                mock(FixedAssetService.class)), sql);
    }

    private record Fixture(FinanceReportService service, List<String> statements) {
        private String sql() {
            return String.join("\n", statements);
        }
    }
}
