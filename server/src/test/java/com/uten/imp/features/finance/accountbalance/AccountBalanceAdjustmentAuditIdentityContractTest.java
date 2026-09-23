package com.uten.imp.features.finance.accountbalance;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class AccountBalanceAdjustmentAuditIdentityContractTest {

    @Test
    void employeeActorAndUserAuditColumnsRemainDistinct() throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/finance/accountbalance/"
                        + "AccountBalanceAdjustmentService.java"));

        assertThat(source)
                .contains("UUID actorEmployeeId = currentUser.requireEmployeeId()")
                .contains("UUID auditUserId = currentUser.requireId()")
                .contains(".setParameter(\"actor\", actorEmployeeId)")
                .contains(".setParameter(\"createdBy\", auditUserId)")
                // ADR-112: 余额与流水统一经账本写入, 操作人仍是用户 id(不是员工 id)。
                .contains("AccountPosting.adjustment(RECON_SOURCE, batchId, batchNo, account.id())")
                .contains(".amounts(delta, deltaLocal)")
                .contains(".actor(auditUserId)");
        String ledger = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/finance/accountflow/AccountFlowLedgerService.java"));
        assertThat(ledger)
                .contains("updated_by = COALESCE(CAST(:actor AS uuid), updated_by)")
                .contains("now(), now(), :actor, :actor, FALSE)")
                .contains(".setParameter(\"entryKind\", adjustment ? \"ADJUSTMENT\" : POSTING)")
                .contains("local = local == null ? null : local.abs();");
    }
}
