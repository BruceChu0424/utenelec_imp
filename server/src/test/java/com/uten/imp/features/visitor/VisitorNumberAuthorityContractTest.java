package com.uten.imp.features.visitor;

import com.uten.imp.common.mastercode.MasterCodePrefix;
import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class VisitorNumberAuthorityContractTest {

    @Test
    void visitorNumberUsesAtomicMasterSequenceAndContainsNoPhoneTail() throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/visitor/VisitorAuthService.java"));
        String lockSource = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/visitor/VisitorAccountCreationLock.java"));

        assertThat(MasterCodePrefix.VISITOR.code()).isEqualTo("V");
        assertThat(MasterCodePrefix.VISITOR.width()).isEqualTo(8);
        assertThat(source)
                .contains("masterCodes.nextCode(MasterCodePrefix.VISITOR)")
                .contains("account.setAvatarSeed(visitorNo)")
                .doesNotContain("existsByVisitorNo")
                .doesNotContain("System.nanoTime()")
                .doesNotContain("phone.substring(phone.length() - 4)");
        assertThat(source.indexOf("accountCreationLock.lock(phoneHash)"))
                .isGreaterThanOrEqualTo(0)
                .isLessThan(source.indexOf("accountRepo.findByPhoneHash(phoneHash)"));
        assertThat(source).doesNotContain("DataIntegrityViolationException");
        assertThat(lockSource)
                .contains("pg_advisory_xact_lock")
                .contains("hashtextextended(CAST(:phoneHash AS text)")
                .contains("Propagation.MANDATORY");
    }
}
