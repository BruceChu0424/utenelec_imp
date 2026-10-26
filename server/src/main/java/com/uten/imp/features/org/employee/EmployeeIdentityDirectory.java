package com.uten.imp.features.org.employee;

import com.uten.imp.application.port.EmployeeIdentityLookupPort;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.Objects;
import java.util.UUID;

/** One organization-owned entry point for explicitly verified employee identities. */
@Service
@RequiredArgsConstructor
@Transactional(readOnly = true)
public class EmployeeIdentityDirectory implements EmployeeIdentityLookupPort {
    private final JdbcTemplate jdbc;

    @Override
    public UUID canonicalEmployeeId(UUID employeeId) {
        return jdbc.queryForObject("SELECT fn_canonical_employee_identity(?)", UUID.class,
                Objects.requireNonNull(employeeId));
    }

    @Override
    public List<UUID> employeeIdentityMembers(UUID employeeId) {
        return List.copyOf(jdbc.queryForList(
                "SELECT employee_id FROM fn_employee_identity_members(?) ORDER BY employee_id",
                UUID.class, Objects.requireNonNull(employeeId)));
    }
}
