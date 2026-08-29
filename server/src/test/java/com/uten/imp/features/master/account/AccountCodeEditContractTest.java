package com.uten.imp.features.master.account;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class AccountCodeEditContractTest {

    @Test
    void accountCreateAndUpdateResolveExplicitCodeWhileDatabaseKeepsLifetimeAuthority()
            throws Exception {
        String service = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/master/account/AccountService.java"));
        String v276 = Files.readString(Path.of(
                "src/main/resources/db/migration/V276__master_code_lifetime_reservations.sql"));
        String v279 = Files.readString(Path.of(
                "src/main/resources/db/migration/V279__global_business_identifier_registry.sql"));

        assertThat(service)
                .contains("a.setCode(resolveCode(req, null))")
                .contains("a.setCode(resolveCode(req, a))")
                .contains("existsByCodeIgnoreCaseAndDeletedFalse")
                .contains("existing == null ? masterCodeService.nextCode(CODE_PREFIX) : existing.getCode()");
        assertThat(v276)
                .contains("CREATE TRIGGER trg_reserve_code_accounts BEFORE INSERT OR UPDATE OF code ON accounts");
        assertThat(v279)
                .contains("CREATE TRIGGER trg_global_identifier_accounts BEFORE INSERT OR UPDATE OF code ON accounts");
    }
}
