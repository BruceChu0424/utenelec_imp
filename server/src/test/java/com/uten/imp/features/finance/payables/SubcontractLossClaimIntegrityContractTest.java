package com.uten.imp.features.finance.payables;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;

class SubcontractLossClaimIntegrityContractTest {

    private static final Path MAIN = Path.of("src/main/java/com/uten/imp");
    private static final Path MIGRATIONS = Path.of("src/main/resources/db/migration");

    @Test
    void reversedOffsetHistoryAndClaimLedgerReversalUseACompatibleRetentionStrategy() throws IOException {
        String offsetMigration = read(MIGRATIONS.resolve("V332__supplier_open_item_offsets.sql"));
        String claimService = read(MAIN.resolve(
                "features/finance/payables/SubcontractLossClaimService.java"));
        String arApService = read(MAIN.resolve(
                "features/finance/arap/ArApLedgerServiceImpl.java"));

        boolean offsetRowsRestrictLedgerDeletion = Pattern.compile(
                        "(?s)(source_ledger_id|target_ledger_id).*?REFERENCES\\s+ar_ap_ledger\\(id\\)\\s+ON\\s+DELETE\\s+RESTRICT")
                .matcher(offsetMigration).find();
        boolean claimCallsPhysicalLedgerReversal = claimService.contains(
                "arApService.reverseArAp(resolutionId, AP_SOURCE_TYPE)");
        boolean arApReversalPhysicallyDeletes = arApService.contains("repo.deleteAll(rows)")
                || arApService.contains("repo.delete(ledger)");

        assertThat(offsetRowsRestrictLedgerDeletion
                && claimCallsPhysicalLedgerReversal
                && arApReversalPhysicallyDeletes)
                .as("REVERSED offset rows cannot retain RESTRICT FKs while claim reversal physically deletes their ledger")
                .isFalse();
    }

    @Test
    void physicalCompensationEvidenceIsLineBoundQuantityCheckedAndSingleUse() throws IOException {
        String service = read(MAIN.resolve(
                "features/finance/payables/SubcontractLossClaimService.java"));
        String method = between(service,
                "private void recordFulfillmentDocument",
                "private SourceCost sourceCost");

        assertThat(method)
                .as("a same-supplier document alone is not evidence for a specific material-loss line")
                .containsAnyOf("order_item_id", "goods_id", "case_line_id");
        assertThat(method)
                .as("the approved document quantity must cover the resolution quantity")
                .containsAnyOf("resolution.quantity()", "fulfilled_qty", "available_qty");
        assertThat(method)
                .as("one receipt/return must not be reused to settle multiple claim resolutions")
                .containsAnyOf("fulfillment_doc_id", "claim_fulfillment_allocations", "subcontract_loss_fulfillment_allocations", "document_item_id");
    }

    @Test
    void cashCompensationHasARealSettlementPathInsteadOfAPermanentPendingState() throws IOException {
        String service = read(MAIN.resolve(
                "features/finance/payables/SubcontractLossClaimService.java"));
        boolean hardBlocked = service.contains(
                "现金赔偿必须先进入专用资金收款与银行对账，当前不能用手工证据冒充到账");
        boolean hasDedicatedPath = service.contains("fulfillCashCompensation")
                || service.contains("CASH_RECEIPT")
                || service.contains("cashCompensationSettlement");

        assertThat(hardBlocked && !hasDedicatedPath)
                .as("CASH_COMPENSATION must be resolvable through a bank-backed path")
                .isFalse();
    }

    @Test
    void claimAmountTotalsOnlyMonetaryRecoveryResolutions() throws IOException {
        String service = read(MAIN.resolve(
                "features/finance/payables/SubcontractLossClaimService.java"));
        String decision = between(service,
                "public CaseDetail decide",
                "public CaseDetail fulfill");

        assertThat(decision)
                .as("company-bear, waiver and quantity-only replacement rows must not inflate claim_amount_local")
                .containsPattern("(?s)if\\s*\\(MONEY_TYPES\\.contains\\(type\\)\\)\\s*(?:\\{\\s*)?claimTotal\\s*=\\s*claimTotal\\.add\\(amount\\)");
    }

    private static String between(String source, String start, String end) {
        int from = source.indexOf(start);
        int to = source.indexOf(end, from + start.length());
        assertThat(from).as("start marker %s", start).isGreaterThanOrEqualTo(0);
        assertThat(to).as("end marker %s", end).isGreaterThan(from);
        return source.substring(from, to);
    }

    private static String read(Path path) throws IOException {
        return Files.readString(path);
    }
}
