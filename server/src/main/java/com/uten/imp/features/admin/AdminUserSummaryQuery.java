package com.uten.imp.features.admin;

import com.uten.imp.common.identity.CurrentEmployeeStatusPolicy;
import com.uten.imp.common.util.KeywordSearch;
import com.uten.imp.features.admin.dto.UserSummary;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.support.PageableExecutionUtils;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;

import java.time.OffsetDateTime;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

/** Bounded account summaries: one page query, no credential or per-employee entity loading. */
@Repository
@RequiredArgsConstructor
class AdminUserSummaryQuery {
    private static final String FROM = """
            FROM users account
            LEFT JOIN employees employee ON employee.id = account.employee_id
            """;
    private static final String DISPLAY_JOINS = """
            LEFT JOIN departments department ON department.id = employee.department_id
            LEFT JOIN positions position ON position.id = employee.position_id
            """;
    private static final String COLUMNS = """
            SELECT account.id, account.employee_id AS bound_employee_id, account.login_account,
                   account.is_super_admin, account.status, account.must_change_password,
                   account.last_login_at, account.remote_access, account.temp_password_expires_at,
                   employee.id AS employee_id, employee.full_name, employee.code,
                   employee.status AS employee_status, department.id AS department_id,
                   department.name AS department_name, position.name AS position_name
            """;
    private static final String[] SEARCH_FIELDS = {
            "employee.full_name", "employee.code", "account.login_account"
    };
    private static final String LIST_FILTER = "WHERE account.is_deleted = FALSE"
            + " AND (employee.id IS NULL OR employee.is_deleted = FALSE)\n";
    private final NamedParameterJdbcTemplate jdbc;
    private final AdminUserSupport support;

    Page<UserSummary> list(Pageable pageable, String search, String status) {
        Map<String, Object> parameters = new LinkedHashMap<>();
        StringBuilder where = new StringBuilder(LIST_FILTER);
        boolean searched = !KeywordSearch.terms(search).isEmpty();
        if (searched) {
            where.append(" AND ").append(KeywordSearch.nativeCondition(search, "accountSearch",
                    java.util.Arrays.stream(SEARCH_FIELDS).map(field -> "lower(" + field + ")").toArray(String[]::new)));
            KeywordSearch.bindNative(parameters, search, "accountSearch");
        }
        if (status != null && !status.isBlank()) {
            where.append(" AND account.status = :accountStatus\n");
            parameters.put("accountStatus", status);
        }
        String ordering = "account.login_account, account.id";
        if (searched) {
            parameters.put("accountPhrase", KeywordSearch.phrase(search));
            parameters.put("accountPrefix", KeywordSearch.prefixPattern(KeywordSearch.phrase(search)));
            parameters.put("accountContains", KeywordSearch.containsPattern(KeywordSearch.phrase(search)));
            // Keep the existing whole-phrase tiers across all three identity fields.
            ordering = "CASE WHEN " + alternatives("lower(btrim(%s)) = :accountPhrase")
                    + " THEN 0 WHEN " + alternatives("lower(%s) LIKE :accountPrefix ESCAPE '\\'")
                    + " THEN 1 WHEN " + alternatives("lower(%s) LIKE :accountContains ESCAPE '\\'")
                    + " THEN 2 ELSE 3 END, employee.full_name, employee.code, " + ordering;
        }
        parameters.put("pageSize", pageable.getPageSize());
        parameters.put("pageOffset", pageable.getOffset());
        var rows = jdbc.query(COLUMNS + FROM + DISPLAY_JOINS + where + "\nORDER BY " + ordering
                + " LIMIT :pageSize OFFSET :pageOffset", parameters, mapper());
        // Preserve Spring Data's exact-count contract and its partial-page count elision.
        return PageableExecutionUtils.getPage(rows, pageable, () -> {
            Long total = jdbc.queryForObject("SELECT count(*) " + FROM + where, parameters, Long.class);
            return total == null ? 0L : total;
        });
    }

    Optional<UserSummary> byEmployeeId(UUID employeeId) {
        return jdbc.query(COLUMNS + FROM + DISPLAY_JOINS
                + "WHERE account.is_deleted = FALSE AND account.employee_id = :employeeId",
                Map.of("employeeId", employeeId), mapper()).stream().findFirst();
    }

    Optional<UserSummary> byId(UUID userId) {
        return jdbc.query(COLUMNS + FROM + DISPLAY_JOINS + LIST_FILTER + " AND account.id = :userId",
                Map.of("userId", userId), mapper()).stream().findFirst();
    }

    private static String alternatives(String expression) {
        return "(" + String.join(" OR ", java.util.Arrays.stream(SEARCH_FIELDS)
                .map(expression::formatted).toList()) + ")";
    }

    private RowMapper<UserSummary> mapper() {
        return (rs, row) -> {
            UUID id = rs.getObject("id", UUID.class);
            UUID employeeId = rs.getObject("employee_id", UUID.class);
            String employeeStatus = rs.getString("employee_status");
            boolean superAdmin = rs.getBoolean("is_super_admin");
            return new UserSummary(id, employeeId, rs.getString("login_account"),
                    rs.getString("full_name"), rs.getString("code"), employeeStatus,
                    employeeId != null && CurrentEmployeeStatusPolicy.isCurrentEmployee(employeeStatus),
                    rs.getObject("department_id", UUID.class), rs.getString("department_name"),
                    rs.getString("position_name"), rs.getString("status"), rs.getBoolean("must_change_password"),
                    rs.getObject("last_login_at", OffsetDateTime.class), rs.getBoolean("remote_access"),
                    rs.getObject("temp_password_expires_at", OffsetDateTime.class),
                    support.canSupportTarget(id, superAdmin),
                    support.canResetPasswordTarget(id, rs.getObject("bound_employee_id", UUID.class), superAdmin));
        };
    }
}
