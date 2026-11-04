package com.uten.imp.features.auth;

import com.uten.imp.application.port.ApprovalCandidateDirectoryPort;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import java.util.*;

/** One current-authority statement per permission/transaction, shared by approval domains. */
@Component
@RequiredArgsConstructor
class ApprovalCandidateDirectoryAdapter implements ApprovalCandidateDirectoryPort {
    private final NamedParameterJdbcTemplate jdbc;
    private final PermissionResolver permissions;

    @Override public List<Candidate> candidates(String permission) {
        return candidates(permission,Set.of());
    }

    @Override public List<Candidate> candidates(String permission,Set<String> prerequisites) {
        if(permission==null||permission.isBlank())return List.of();
        Set<String> required=new LinkedHashSet<>(prerequisites);required.add(permission);
        var key=List.of(this,permission,Set.copyOf(required));
        if(TransactionSynchronizationManager.hasResource(key)) {
            @SuppressWarnings("unchecked") var cached=(List<Candidate>)TransactionSynchronizationManager.getResource(key);
            return cached;
        }
        var active=jdbc.query("""
                SELECT account.id,employee.id AS employee_id FROM users account
                JOIN employees employee ON employee.id=account.employee_id
                WHERE NOT account.is_deleted AND account.status='active' AND NOT account.must_change_password
                  AND (account.locked_until IS NULL OR account.locked_until<=now()) AND NOT employee.is_deleted
                  AND employee.status IN(:statuses) ORDER BY account.id
                """,Map.of("statuses",com.uten.imp.common.identity.CurrentEmployeeStatusPolicy.CURRENT_EMPLOYEE_STATUSES),
                (row,index)->new Candidate(row.getObject("id",UUID.class),row.getObject("employee_id",UUID.class)));
        var grants=permissions.grantedPermissionsFor(active.stream().map(Candidate::userId).toList(),Set.copyOf(required));
        var result=active.stream().filter(candidate->grants.getOrDefault(candidate.userId(),Set.of()).containsAll(required)).toList();
        if(TransactionSynchronizationManager.isSynchronizationActive()) {
            TransactionSynchronizationManager.bindResource(key,result);
            TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
                @Override public void afterCompletion(int status){TransactionSynchronizationManager.unbindResourceIfPossible(key);}
            });
        }
        return result;
    }
}
