package com.uten.imp.features.master.client;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ClientAccessLockOrderContractTest {

    @Test
    void updateCallsEmployeesThenClientThenUsersThenGrantsAndRechecksCas() throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/master/client/ClientAccessService.java"));
        String update = source.substring(
                source.indexOf("public ClientAccessDetail update("),
                source.indexOf("private ValidatedRequest validateRequest"));

        int employeeLock = update.indexOf("employeeReferences(lockedEmployees)");
        int clientLock = update.indexOf("requireClientForUpdate(clientId)");
        int userLock = update.indexOf("activeAccountEmployeeIds(lockedEmployees)");
        int grantWrite = update.indexOf("replaceViewers(");
        assertThat(employeeLock).isGreaterThanOrEqualTo(0);
        assertThat(clientLock).isGreaterThan(employeeLock);
        assertThat(userLock).isGreaterThan(clientLock);
        assertThat(grantWrite).isGreaterThan(userLock);
        assertThat(update)
                .contains("snapshot.getOwnerEmployeeId(), client.getOwnerEmployeeId()")
                .contains("client.getAccessVersion() != validated.expectedAccessVersion()");

        assertThat(source)
                .contains("ORDER BY employee.id\n                        FOR SHARE OF employee")
                .contains("ORDER BY account.employee_id, account.id\n                        FOR SHARE OF account")
                .contains("em.refresh(client, LockModeType.PESSIMISTIC_WRITE)");
    }
}
