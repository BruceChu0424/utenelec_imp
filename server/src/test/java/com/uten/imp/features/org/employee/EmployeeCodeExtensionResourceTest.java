package com.uten.imp.features.org.employee;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

/** A maintenance installation and its later Flyway adoption must execute the same reviewed artifact. */
class EmployeeCodeExtensionResourceTest {
    @Test void maintenanceAndFutureFlywayShipExactlyTheSameInstallerBytes() throws Exception {
        Path maintenance=Path.of("maintenance/employee_code_reuse_extension_v1.sql");
        if(!Files.isRegularFile(maintenance))maintenance=Path.of("server").resolve(maintenance);
        byte[] installed=Files.readAllBytes(maintenance);
        try(var migration=getClass().getResourceAsStream("/db/migration/V965__employee_code_reuse_extension.sql")) {
            assertThat(migration).isNotNull();
            assertThat(migration.readAllBytes()).isEqualTo(installed);
        }
    }
}
