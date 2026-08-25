package com.uten.imp.responsibility;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class DataHandoverSourceContractTest {

    private static final Path SERVICE = Path.of(
            "src/main/java/com/uten/imp/responsibility/DataHandoverService.java");

    @Test
    void handoverUsesStableScopesIdempotencyAndAtomicBlockers() throws Exception {
        String source = Files.readString(SERVICE, StandardCharsets.UTF_8);

        assertThat(source).contains(
                "goods\", \"client\", \"sales\", \"finance",
                "purchase\", \"subcontract\", \"production_plan\", \"stock_doc",
                "pg_advisory_xact_lock",
                "ORDER BY id FOR UPDATE",
                "requestId 已用于不同的数据交接请求",
                "DataHandoverAction.BLOCKING",
                "status IN ('DISPATCHED','IN_PROGRESS')",
                "lifecycle_status <> 'DISPOSED'",
                "lifecycle_status NOT IN ('COMPLETED','TERMINATED')",
                "status='approved'");
    }

    @Test
    void handoverOnlyMutatesCurrentResponsibilityAndKeepsHistoricalActors() throws Exception {
        String source = Files.readString(SERVICE, StandardCharsets.UTF_8);

        assertThat(source).contains(
                "clientEvents.transfer(",
                "UPDATE goods SET owner_employee_id=:target",
                "UPDATE suppliers SET owner_employee_id=:target",
                "UPDATE moulds SET keeper_id=:target",
                "UPDATE supplier_return_tasks",
                "UPDATE production_execution_segments segment");
        assertThat(source).doesNotContain(
                "SET maker_id=",
                "SET maker_id =",
                "SET approver_id=",
                "SET approver_id =",
                "SET created_by=",
                "SET created_by =");
    }

    @Test
    void offboardingCleanupRevokesDepartingAccessAndReleasesClaims() throws Exception {
        String source = Files.readString(SERVICE, StandardCharsets.UTF_8);

        assertThat(source).contains(
                "disablePersonalOverrides(sourceEmployeeId)",
                "disableManagerDelegations(sourceEmployeeId, actorUserId)",
                "hardenDepartingAccount(sourceEmployeeId)",
                "deleteDataScopes(sourceEmployeeId)",
                "clientEvents.revokeViewerForOffboarding(",
                "rejectPendingProfileChanges(sourceEmployeeId",
                "releaseClaims(sourceEmployeeId",
                "SET active=false, row_version=row_version+1",
                "SET enabled=false, row_version=row_version+1",
                "remote_access=false, must_change_password=true",
                "release_reason='employee_handover'",
                "UPDATE hr_task_claims SET released_at=now()");
    }
}
