package com.uten.imp.features.auth;

import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class StaffAuthenticationPolicyTest {
    @Test void onlyTheCanonicalCurrentEmployeeStatesAreAuthenticatable() {
        UUID employee=UUID.randomUUID();
        for(String status:java.util.List.of("active","probation","onLeave")) {
            assertTrue(StaffAuthenticationPolicy.currentEmployee(employee,false,status),status);
            assertFalse(StaffAuthenticationPolicy.currentEmployee(employee,true,status),status);
            assertFalse(StaffAuthenticationPolicy.currentEmployee(null,false,status),status);
        }
        for(String status:java.util.List.of("resigned","on_leave","","unknown"))
            assertFalse(StaffAuthenticationPolicy.currentEmployee(employee,false,status),status);
        assertFalse(StaffAuthenticationPolicy.currentEmployee(employee,false,null));
    }

    @Test void superAdminStatusDoesNotBypassTheSameCurrentIdentityLookup() {
        var users=mock(UserAccountRepository.class);var account=new UserAccount();account.setEmployeeId(UUID.randomUUID());
        for(boolean superAdmin:new boolean[]{false,true}) {
            account.setSuperAdmin(superAdmin);
            assertFalse(StaffAuthenticationPolicy.currentEmployee(users,account));
        }
    }

    @Test void onlyAnOutstandingTemporaryCredentialExpiresAndNullKeepsTheLegacyContract() {
        Instant past=Instant.now().minusSeconds(1),future=Instant.now().plusSeconds(60);
        assertTrue(StaffAuthenticationPolicy.temporaryPasswordExpired(true,past));
        assertFalse(StaffAuthenticationPolicy.temporaryPasswordExpired(true,future));
        assertFalse(StaffAuthenticationPolicy.temporaryPasswordExpired(true,null));
        assertFalse(StaffAuthenticationPolicy.temporaryPasswordExpired(false,past));
        var account=new UserAccount();account.setMustChangePassword(true);account.setTempPasswordExpiresAt(OffsetDateTime.now().minusSeconds(1));
        assertThrows(com.uten.imp.common.web.ApiException.class,()->StaffAuthenticationPolicy.requireCurrentTemporaryPassword(account));
        account.setMustChangePassword(false);assertDoesNotThrow(()->StaffAuthenticationPolicy.requireCurrentTemporaryPassword(account));
    }
}
