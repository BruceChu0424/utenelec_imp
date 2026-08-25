package com.uten.imp.responsibility;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ClientHandoverEventRecorderContractTest {

    @Test
    void ownerTransferLocksSnapshotsExpandsExactScopeAndAppendsViewerEvidence()
            throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/responsibility/ClientHandoverEventRecorder.java"),
                StandardCharsets.UTF_8);

        assertThat(source).contains(
                "lockOwnedSnapshots(sourceEmployeeId)",
                "ORDER BY id",
                "FOR UPDATE",
                "eligibleClientScopeRecipients(",
                "recipient.employee_id NOT IN (:source,:target)",
                "upsertViewer(snapshot.clientId(), recipientId, actorUserId)",
                "retainSourceViewer",
                "deactivateViewer(snapshot.clientId(), targetEmployeeId",
                "activeViewerIds(snapshot.clientId())",
                "UPDATE clients",
                "access_version=access_version+1",
                "INSERT INTO client_access_change_events",
                "CAST(:previousViewers AS UUID[])",
                "CAST(:newViewers AS UUID[])",
                "snapshot.accessVersion() + 1",
                "DELETE FROM user_data_scopes data_scope",
                "recipient.employee_id<>:source",
                "TransferOutcome(changed, deletedScopes)",
                "reason.length() > 2000");
    }
}
