package com.uten.imp.businesschain;

import com.uten.imp.security.JwtService;
import java.time.Instant;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import static org.junit.jupiter.api.Assertions.*;

/** The administrator owning an impersonation session must remain eligible, too. */
class ImpersonationOwnerLifecyclePostgresTest extends AuthSessionPostgresTestSupport {
    @Autowired JwtService jwt;

    @Test
    void existingImpersonationCannotOutliveItsOwnersSuperAdminOrEmployeeIdentity() throws Exception {
        var admin = adminToken();
        Employee owner = newEmployee(admin);
        Employee target = newEmployee(admin);
        UUID user = UUID.fromString(owner.userId());
        UUID employee = UUID.fromString(owner.employeeId());
        jdbc.update("UPDATE users SET is_super_admin=true WHERE id=?", user);
        login(owner.loginAccount(), EMPLOYEE_PASSWORD);
        String simulated = impersonation(owner, target);
        assertEquals(200, me(simulated).getResponse().getStatus());
        record Mutation(String label, String sql) {}
        var mutations = List.of(
                new Mutation("super-admin revoked", "UPDATE users SET is_super_admin=false WHERE id=?"),
                new Mutation("owner disabled", "UPDATE users SET status='disabled' WHERE id=?"),
                new Mutation("owner manually locked", "UPDATE users SET status='locked',locked_until=NULL WHERE id=?"),
                new Mutation("owner account archived", "UPDATE users SET is_deleted=true WHERE id=?"),
                new Mutation("owner employee archived", "UPDATE employees SET is_deleted=true WHERE id=?"),
                new Mutation("owner employee resigned", "UPDATE employees SET status='resigned' WHERE id=?"),
                new Mutation("owner must change password", "UPDATE users SET must_change_password=true,temp_password_expires_at=now()+interval '1 hour' WHERE id=?"),
                new Mutation("owner temporary password expired", "UPDATE users SET must_change_password=true,temp_password_expires_at=now()-interval '1 second' WHERE id=?"));
        for (var mutation : mutations) {
            try {
                jdbc.update(mutation.sql(), mutation.sql().startsWith("UPDATE employees") ? employee : user);
                // An already authenticated start request can finish target-token
                // assembly after its owner's eligibility changes. Target stamps
                // alone cannot stand in for the owner of the retained SID.
                assertEquals(401, me(impersonation(owner, target)).getResponse().getStatus(), mutation.label());
                assertEquals(200, me(freshAccess(target)).getResponse().getStatus(), "The target's own independent session must remain usable: " + mutation.label());
            } finally {
                jdbc.update("UPDATE users SET is_super_admin=true,status='active',locked_until=NULL,is_deleted=false,must_change_password=false,temp_password_expires_at=NULL WHERE id=?", user);
                jdbc.update("UPDATE employees SET status='active',is_deleted=false WHERE id=?", employee);
            }
        }
    }

    @Test
    void currentSuperAdminOwnersMayStillUseTheirOriginalReadOnlyImpersonation() throws Exception {
        String admin = adminToken();
        Employee owner = newEmployee(admin);
        Employee target = newEmployee(admin);
        jdbc.update("UPDATE users SET is_super_admin=true WHERE id=?", UUID.fromString(owner.userId()));
        login(owner.loginAccount(), EMPLOYEE_PASSWORD);
        for (String status : List.of("active", "probation", "onLeave")) {
            jdbc.update("UPDATE employees SET status=? WHERE id=?", status, UUID.fromString(owner.employeeId()));
            assertEquals(200, me(impersonation(owner, target)).getResponse().getStatus(), status);
        }
    }

    private String impersonation(Employee owner, Employee target) {
        UUID user = UUID.fromString(target.userId());
        UUID sid = jdbc.queryForObject("SELECT sid FROM auth_sessions WHERE user_id=? AND revoked_at IS NULL", UUID.class, UUID.fromString(owner.userId()));
        long authVersion = jdbc.queryForObject("SELECT auth_version FROM users WHERE id=?", Long.class, user);
        long epoch = jdbc.queryForObject("SELECT epoch FROM authorization_state WHERE singleton_id=1", Long.class);
        return jwt.issueImpersonationAccess(user, authVersion, epoch, UUID.fromString(owner.userId()), Instant.now().plusSeconds(300), sid);
    }

    private String freshAccess(Employee employee) {
        UUID user = UUID.fromString(employee.userId());
        UUID sid = jdbc.queryForObject("SELECT sid FROM auth_sessions WHERE user_id=? AND revoked_at IS NULL", UUID.class, user);
        long version = jdbc.queryForObject("SELECT auth_version FROM users WHERE id=?", Long.class, user);
        long epoch = jdbc.queryForObject("SELECT epoch FROM authorization_state WHERE singleton_id=1", Long.class);
        return jwt.issueAccess(user, version, epoch, sid);
    }
}
