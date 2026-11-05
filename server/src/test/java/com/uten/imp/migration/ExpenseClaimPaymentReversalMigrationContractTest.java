package com.uten.imp.migration;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.HashSet;
import java.util.HexFormat;
import java.util.Set;
import java.util.regex.Pattern;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class ExpenseClaimPaymentReversalMigrationContractTest {
    @Test void forwardConstraintAddsOnlyTheMissingEventAndKeepsAppliedNativeMigrationBytes() throws Exception {
        Path directory=Path.of("src/main/resources/db/migration");
        Path nativeStage=directory.resolve("V1000__expense_department_finance_executive_workflow.sql");
        Path nativeAbandonment=directory.resolve("V1002__department_approval_substitution_policy.sql");
        assertThat(sha(nativeStage)).isEqualTo("1826c869dbf9e306c25458ec689d8c8cf09b5bb4316e97c3946b6f89b15b786e");
        assertThat(sha(nativeAbandonment)).isEqualTo("b8c390e8969153bb65ab05c956cc61cc36886bdd3baf80f47d2ee1fa13758f26");
        String forward=AuditTriggerCoverageMigrationContractTest.stripSqlComments(Files.readString(
                directory.resolve("V1069__expense_claim_payment_reversal_event_contract.sql"),StandardCharsets.UTF_8));
        var existing=eventTypes(Files.readString(nativeAbandonment,StandardCharsets.UTF_8));
        var expected=new HashSet<>(existing);expected.add("PAYMENT_REVERSED");
        assertThat(existing).contains("STAGE_APPROVED","ABANDONED").hasSize(9);
        assertThat(eventTypes(forward)).isEqualTo(expected).hasSize(10);
        assertThat(Pattern.compile("(?i)\\b(?:INSERT|UPDATE|DELETE|TRUNCATE|CREATE\\s+TABLE|DROP\\s+TABLE|NOT\\s+VALID)\\b")
                .matcher(forward).find()).isFalse();
    }
    private static Set<String> eventTypes(String sql) {
        var check=Pattern.compile("(?is)ADD\\s+CONSTRAINT\\s+expense_claim_events_type_chk\\s+CHECK\\s*\\(\\s*event_type\\s+IN\\s*\\((.*?)\\)\\s*\\)").matcher(sql);
        if(!check.find())throw new AssertionError("Missing exact expense-event constraint");
        var quoted=Pattern.compile("'([A-Z_]+)'").matcher(check.group(1));var values=new HashSet<String>();
        while(quoted.find())if(!values.add(quoted.group(1)))throw new AssertionError("Duplicate event type");
        return values;
    }
    private static String sha(Path path) throws Exception {
        return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(path)));
    }
}
