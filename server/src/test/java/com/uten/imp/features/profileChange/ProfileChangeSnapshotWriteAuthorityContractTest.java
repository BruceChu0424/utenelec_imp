package com.uten.imp.features.profilechange;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Locale;

import static org.assertj.core.api.Assertions.assertThat;

class ProfileChangeSnapshotWriteAuthorityContractTest {

    private static final Path ROOT = Path.of(
            "src/main/java/com/uten/imp/features/profileChange");
    private static final Path JAVA_ROOT = Path.of("src/main/java/com/uten/imp");

    @Test
    void submitReadAndApprovalAllUseTheSnapshotCodec() throws IOException {
        String submit = compact(Files.readString(ROOT.resolve(
                "ProfileChangeSubmitService.java")));
        String mapper = compact(Files.readString(ROOT.resolve(
                "ProfileChangeMapper.java")));
        String applier = compact(Files.readString(ROOT.resolve(
                "ProfileFieldApplier.java")));
        String review = compact(Files.readString(ROOT.resolve(
                "ProfileChangeReviewService.java")));
        String query = compact(Files.readString(ROOT.resolve(
                "ProfileChangeQueryService.java")));
        String runner = compact(Files.readString(ROOT.resolve(
                "ProfileChangeSnapshotBackfillRunner.java")));
        String employeeCommand = compact(Files.readString(JAVA_ROOT.resolve(
                "features/org/employee/EmployeeCommandService.java")));
        String handover = compact(Files.readString(JAVA_ROOT.resolve(
                "responsibility/DataHandoverService.java")));
        String sessionVars = compact(Files.readString(JAVA_ROOT.resolve(
                "security/TxSessionVars.java")));

        assertThat(submit)
                .contains("snapshotcodec.bindwritecapability()")
                .contains("row.setvalueencoding(snapshotcodec.encodingfor(ch.fieldcode()))")
                .contains("row.setoldvalueenc(snapshotcodec.encode(ch.fieldcode(), oldvalue))")
                .contains("row.setnewvalueenc(snapshotcodec.encode(ch.fieldcode(), ch.newvalue()))")
                .doesNotContain("row.setnewvalueenc(ch.newvalue())");
        assertThat(mapper)
                .contains("snapshotcodec.decode( r.getfieldcode(), r.getvalueencoding(), r.getoldvalueenc())")
                .contains("snapshotcodec.decode( r.getfieldcode(), r.getvalueencoding(), r.getnewvalueenc())")
                .doesNotContain("contains(\":\")");
        assertThat(applier)
                .contains("string newvalue = snapshotcodec.decode( fieldcode, row.getvalueencoding(), row.getnewvalueenc())");
        assertThat(review).contains("snapshotcodec.bindwritecapability()");
        assertThat(query).contains("void cancelbatch(uuid batchid) { snapshotcodec.bindwritecapability()");
        assertThat(runner).contains("private boolean migrateone(uuid id) { codec.bindwritecapability()");
        assertThat(employeeCommand)
                .contains("void offboard(uuid id, offboardrequest req) { tx.bind(); tx.bindprofilechangesnapshotcodecv1()")
                .contains("datahandoverservice.executeoffboarding(");
        assertThat(handover)
                .contains("update profile_change_requests set status='rejected', reviewed_by=:actoremployee, reviewed_at=now()")
                .contains("where employee_id=:source and status='pending'")
                .contains("changed(\"workflow.profilechanges\", rejectpendingprofilechanges(");
        assertThat(sessionVars)
                .contains("setconfig(\"app.profile_change_snapshot_codec\", \"v1\")");
    }

    @Test
    void historicalRunnerIsBoundedDurableAndFailsOnRemainingUnknownRows()
            throws IOException {
        String runner = compact(Files.readString(ROOT.resolve(
                "ProfileChangeSnapshotBackfillRunner.java")));

        assertThat(runner)
                .contains("private static final int batch_size = 200")
                .contains("where value_encoding = 'legacy_unknown' order by id limit ?")
                .contains("for update")
                .contains("value_encoding = 'pgcrypto_v1'")
                .contains("remaining != 0")
                .contains("canonicalizelegacysensitive")
                .doesNotContain("logger.debug(row.oldvalue")
                .doesNotContain("logger.debug(row.newvalue");
    }

    private static String compact(String value) {
        return value.toLowerCase(Locale.ROOT).replaceAll("\\s+", " ").trim();
    }
}
