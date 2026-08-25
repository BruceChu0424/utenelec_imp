package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertTrue;

class ResponsibilityLockOrderMigrationContractTest {

    @Test
    void dataScopeGuardLocksEmployeeBeforeUser() throws Exception {
        String sql = Files.readString(Path.of(
                "src/main/resources/db/migration/"
                        + "V397__data_scope_employee_user_lock_order.sql"));

        int employeeLock = sql.indexOf("FOR SHARE OF employee");
        int userLock = sql.indexOf("FOR SHARE OF account", employeeLock + 1);
        assertTrue(employeeLock >= 0, "employee row lock must be explicit");
        assertTrue(userLock > employeeLock, "lock order must stay employee -> user");
        assertTrue(sql.contains("v_account_employee_id IS DISTINCT FROM v_employee_id"),
                "account/employee binding must be rechecked after both locks");
    }
}
