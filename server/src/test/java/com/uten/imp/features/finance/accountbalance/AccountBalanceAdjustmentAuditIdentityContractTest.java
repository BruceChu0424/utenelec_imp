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
                .contains("updated_at=now(),updated_by=:actor")
                .contains(".setParameter(\"actor\", auditUserId)")
                .contains("in_amount,out_amount,amount_local,entry_kind,bill_date,settled_date")
                .contains(":inAmount,:outAmount,:amountLocal,'ADJUSTMENT',:billDate,NULL")
                .contains(".setParameter(\"amountLocal\", deltaLocal.abs())");
    }
}
