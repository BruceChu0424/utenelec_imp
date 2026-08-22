package com.uten.imp.features.finance.payables;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class SupplierClosedPeriodLockOrderContractTest {
    private static final Path MAIN = Path.of("src", "main", "java", "com", "uten", "imp", "features");

    @Test
    void guardSerializesOnSupplierBeforeReadingTheClosedThroughDate() throws Exception {
        String source = read("finance", "payables", "SupplierClosedPeriodGuard.java");
        assertThat(source)
                .contains("FOR SHARE")
                .contains("status <> 'REVERSED'")
                .contains("supplier_confirmed_at IS NOT NULL")
                .contains("internal_confirmed_at IS NOT NULL")
                .contains("OR status='CLOSED'")
                .doesNotContain("status IN ('BOTH_CONFIRMED','CLOSED')")
                .contains("!businessDate.isAfter(closedThrough)");
        assertThat(source.indexOf("FOR SHARE"))
                .isLessThan(source.indexOf("SELECT MAX(period_end)"));
    }

    @Test
    void paymentGuardsBeforePaymentRowLockAndRevalidatesIdentity() throws Exception {
        String source = read("finance", "payment", "FinancePaymentService.java");
        assertOrdered(between(source, "public FinancePaymentDetail approve", "/** 红冲"),
                "closedPeriodGuard.requireOpen", "PESSIMISTIC_WRITE",
                "requirePeriodIdentityUnchanged");
        assertOrdered(between(source, "public FinancePaymentDetail reverse", "// ===================== 核销逻辑"),
                "closedPeriodGuard.requireOpen", "PESSIMISTIC_WRITE",
                "requirePeriodIdentityUnchanged");
    }

    @Test
    void procurementAndSubcontractDocumentsGuardBeforeBusinessLocks() throws Exception {
        for (String[] spec : new String[][]{
                {"purchase", "receipt", "PurchaseReceiptService.java", "ReceiptDetail"},
                {"purchase", "ret", "PurchaseReturnService.java", "ReturnDetail"},
                {"subcontract", "receipt", "SubcontractReceiptService.java", "ReceiptDetail"},
                {"subcontract", "ret", "SubcontractReturnService.java", "ReturnDetail"}}) {
            String source = read(spec[0], spec[1], spec[2]);
            String approve = between(source, "public " + spec[3] + " approve",
                    "public " + spec[3] + " reverse");
            assertOrdered(approve, "periodIdentity(id)", "closedPeriodGuard.requireOpen",
                    "require" + spec[3].replace("Detail", "") + "ForUpdate",
                    "requirePeriodIdentityUnchanged");
            assertThat(approve).contains("periodIdentity.billDate()");

            String reverse = between(source, "public " + spec[3] + " reverse",
                    "private void applyMovement");
            assertOrdered(reverse, "periodIdentity(id)", "closedPeriodGuard.requireOpen",
                    "require" + spec[3].replace("Detail", "") + "ForUpdate",
                    "requirePeriodIdentityUnchanged");
            assertThat(reverse).contains("BusinessTime.today()");
        }
    }

    @Test
    void offsetReverseGuardsBeforeOffsetAndLedgerLocksThenRevalidates() throws Exception {
        String method = between(
                read("finance", "payables", "SupplierOpenItemOffsetService.java"),
                "public void reverseBatch", "private Map<UUID, OpenItem> lock");
        assertOrdered(method, "SELECT DISTINCT supplier_id,currency_id",
                "closedPeriodGuard.requireOpen", "FOR UPDATE",
                "Map<UUID, OpenItem> locked");
        assertThat(method).contains("抵销批次身份已变化");
    }

    @Test
    void offsetApplyFacadeGuardsBeforeGlAndLedgerLocks() throws Exception {
        String method = between(
                read("finance", "payables", "SupplierOffsetCommandService.java"),
                "public ApplyResult apply", "@Transactional\n    public void reverse");
        assertOrdered(method, "SELECT supplier_id,currency_id,open_item_kind",
                "closedPeriodGuard.requireOpen", "glPosting.lockAutoProjectionPeriod",
                "offsets.applyBatch");
        assertThat(method).doesNotContain("FOR UPDATE");
    }

    @Test
    void settlementStateTransitionsTakeSupplierBeforeBatchLockAndRevalidate() throws Exception {
        String source = read("finance", "payables", "SupplierSettlementService.java");
        for (String[] markers : new String[][]{
                {"public BatchDetail supplierConfirm", "@Transactional\n    public BatchDetail internalConfirm"},
                {"public BatchDetail internalConfirm", "@Transactional\n    public BatchDetail dispute"},
                {"public BatchDetail dispute", "@Transactional\n    public BatchDetail reverse"},
                {"public BatchDetail reverse", "private List<SnapshotLine> snapshotLines"}}) {
            String method = between(source, markers[0], markers[1]);
            assertOrdered(method, "batchPeriodIdentity", "lockSupplier",
                    "lockBatch", "requireBatchPeriodIdentityUnchanged");
        }
    }

    @Test
    void claimCommandsGuardBeforeCaseLocksAndRevalidateIdentity() throws Exception {
        String source = read("finance", "payables", "SubcontractLossClaimService.java");
        for (String[] markers : new String[][]{
                {"public CaseDetail decide", "@Transactional\n    public CaseDetail fulfill"},
                {"public CaseDetail fulfill", "@Transactional\n    public CaseDetail reverseFulfillment"},
                {"public CaseDetail reverseFulfillment", "private CaseDetail reverseCashCompensationFulfillment"},
                {"public CaseDetail reverse(UUID", "private void validateResolutionCoverage"}}) {
            String method = between(source, markers[0], markers[1]);
            assertOrdered(method, "casePeriodIdentity", "closedPeriodGuard.requireOpen",
                    "lockCase", "requireCasePeriodIdentityUnchanged");
        }
    }

    @Test
    void arApCenterGuardsBeforeProjectionOrLedgerWriteLocks() throws Exception {
        String source = read("finance", "arap", "ArApLedgerServiceImpl.java");
        assertOrdered(between(source, "public void postArAp", "/**\n     * 反立帐"),
                "closedPeriodGuard.requireOpen", "glPosting.lockAutoProjectionPeriod",
                "findBySourceForUpdate");
        assertOrdered(between(source, "public void reverseArAp", "private static String projectionSourceType"),
                "closedPeriodGuard.requireOpen", "glPosting.lockAutoProjectionPeriod",
                "findBySourceForUpdate");
    }

    private static void assertOrdered(String source, String... tokens) {
        int prior = -1;
        for (String token : tokens) {
            int index = source.indexOf(token);
            assertThat(index).as("missing token %s", token).isGreaterThan(prior);
            prior = index;
        }
    }

    private static String between(String source, String start, String end) {
        String normalized = source.replace("\r\n", "\n");
        int from = normalized.indexOf(start);
        int to = normalized.indexOf(end, from + start.length());
        assertThat(from).as("start marker %s", start).isGreaterThanOrEqualTo(0);
        assertThat(to).as("end marker %s", end).isGreaterThan(from);
        return normalized.substring(from, to);
    }

    private static String read(String... parts) throws Exception {
        Path path = MAIN;
        for (String part : parts) path = path.resolve(part);
        return Files.readString(path);
    }
}
