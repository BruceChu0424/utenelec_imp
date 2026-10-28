package com.uten.imp.features.finance.payables;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class SupplierPayableHistoricalStatementContractTest {
    private static final Path MAIN = Path.of("src", "main", "java", "com", "uten", "imp", "features");

    @Test
    void monthlyFreezeValidatesTheExactSnapshotRowsPaymentMethod() throws Exception {
        String service = read("finance", "payables", "SupplierSettlementService.java");
        String snapshotSql = read("finance", "payables", "SupplierSettlementSnapshotSql.java").replace("\r\n", "\n");

        assertThat(service)
                .contains("SupplierSettlementSnapshotSql.LINES")
                .contains("moneyValue(row[17]),moneyValue(row[18]),NativeValueConverters.uuid(row[19])")
                .contains("assertSettlementMethodConsistency(lines, request.settlementMethodId())")
                .contains("line.settlementMethodId(), settlementMethodId");
        assertThat(service.indexOf("assertSettlementMethodConsistency(lines, request.settlementMethodId())"))
                .isLessThan(service.indexOf("Totals totals = totals(lines)"));
        // 冻结快照按带日期的立账/红冲窗口取数，期初/本期/期末同源。
        assertThat(snapshotSql)
                .contains("CASE WHEN source.bill_date<:start THEN source.posted_original ELSE 0 END")
                .contains("CASE WHEN source.reversal_date<:start THEN source.posted_original ELSE 0 END")
                .contains("CASE WHEN source.bill_date BETWEEN :start AND :end")
                .contains("CASE WHEN source.bill_date<=:end THEN source.posted_original ELSE 0 END");
    }

    @Test
    void statementAndAnnualShareOneDatedApEventAuthority() throws Exception {
        String report = read("finance", "report", "FinanceReportService.java").replace("\r\n", "\n");
        String statementSql = read("finance", "report", "FinancePartyStatementSql.java").replace("\r\n", "\n");
        String cashSql = read("finance", "report", "FinanceCashEventSql.java").replace("\r\n", "\n");
        String summaryService = read("finance", "report", "PartyMonthlySummaryService.java").replace("\r\n", "\n");

        // B2 三段式：流水/明细仍直接走事件权威；年度改读 party_monthly_summaries 投影，
        // 投影重算必须调用同一份 events 权威 SQL——四处同源，不允许另写一份事件流。
        assertThat(count(report, "FinancePartyStatementSql.events(isAR,scope.predicate())"))
                .as("statement flow/detail must call the shared event authority")
                .isEqualTo(1);
        assertThat(summaryService)
                .as("the monthly projection must be recomputed from the same event authority")
                .contains("FinancePartyStatementSql.events(\"AR\".equals(side), \"1=1\")");
        assertThat(statementSql)
                .contains("party_monthly_summaries")
                .contains("(ledger.deleted_at AT TIME ZONE 'Asia/Shanghai')::date")
                .contains("(allocation.reversed_at AT TIME ZONE 'Asia/Shanghai')::date")
                .contains("offset_facts AS (")
                .contains("FROM @offsets@ allocation")
                .contains("'抵销反转'")
                .contains("'@sourceLabel@使用'")
                .contains("'@sourceLabel@恢复'")
                .contains("\"预收转销\" : \"应付抵销\"")
                .contains("\"预收\" : \"贷项\"")
                // 历史期初按快照截止日定格；迁入后的红冲才允许按删除时间定位。
                .contains("THEN '历史期初' ELSE '立账' END")
                .contains("ledger.legacy_import_run_id IS NULL AND ledger.status=-1")
                .doesNotContain("ledger.deleted_at::date")
                .doesNotContain("allocation.reversed_at::date");
        // 新收付事件只认迁移后的资金事实，并保留带时区的冲销日期。
        assertThat(cashSql)
                .contains("(COALESCE(t.reversed_at,t.updated_at) AT TIME ZONE 'Asia/Shanghai')::date AS reverse_date")
                .contains("t.legacy_id IS NULL AND t.legacy_import_run_id IS NULL")
                .contains("line.applied_amount_local")
                .contains("END AS book_rate");
    }

    private static int count(String source, String token) {
        int count = 0;
        for (int index = 0; (index = source.indexOf(token, index)) >= 0; index += token.length()) {
            count++;
        }
        return count;
    }

    private static String read(String... parts) throws Exception {
        Path file = MAIN;
        for (String part : parts) file = file.resolve(part);
        return Files.readString(file);
    }
}
