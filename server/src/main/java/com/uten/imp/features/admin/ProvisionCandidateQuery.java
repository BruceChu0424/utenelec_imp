package com.uten.imp.features.admin;

import com.uten.imp.common.util.DepartmentSearchSql;
import com.uten.imp.common.util.EmployeeCandidateFilter;
import com.uten.imp.common.util.KeywordSearch;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.admin.dto.ProvisionCandidateDto;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Pageable;
import org.springframework.data.support.PageableExecutionUtils;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;

import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Minimal unprovisioned-employee projection; the owning service retains account-support authority. */
@Repository
@RequiredArgsConstructor
class ProvisionCandidateQuery {
    private final NamedParameterJdbcTemplate jdbc;
    private static final String[] IDENTITY = {"employee.full_name", "employee.code"};
    private static final String PROVISION_COLUMNS = """
            SELECT employee.id, employee.full_name, employee.code, employee.status,
                   employee.department_id, department.name AS department_name, sensitive.phone_enc
            """;
    private static final RowMapper<ProvisionCandidateDto> PROVISION = (rs, row) -> {
        String encryptedPhone = rs.getString("phone_enc");
        return new ProvisionCandidateDto(rs.getObject("id", UUID.class), rs.getString("full_name"),
                rs.getString("code"), rs.getString("department_name"),
                encryptedPhone != null && !encryptedPhone.isBlank(), rs.getObject("department_id", UUID.class),
                "notProvisioned", rs.getString("status"));
    };

    public PageResponse<ProvisionCandidateDto> provisionPage(String search, int page, int size,
            UUID departmentId, boolean includeSubtree) {
        return page(provision(search, departmentId, includeSubtree), PROVISION_COLUMNS, PROVISION, page, size);
    }

    public List<ProvisionCandidateDto> provisionLegacy(String search, int limit) {
        return rows(provision(search, null, false), PROVISION_COLUMNS, PROVISION, limit, 0);
    }

    private Plan provision(String search, UUID departmentId, boolean includeSubtree) {
        return plan(search, departmentId, includeSubtree, """
                FROM employees employee
                LEFT JOIN departments department ON department.id=employee.department_id
                LEFT JOIN employee_sensitive sensitive ON sensitive.employee_id=employee.id
                """, """
                WHERE NOT employee.is_deleted AND employee.status<>'resigned'
                  AND NOT EXISTS (SELECT 1 FROM users existing_account
                      WHERE existing_account.employee_id=employee.id AND NOT existing_account.is_deleted)
                """, "employee.code, employee.id");
    }

    private Plan plan(String search, UUID departmentId, boolean includeSubtree, String from, String where,
            String secondaryOrder) {
        boolean searched = !KeywordSearch.terms(search).isEmpty();
        Map<String, Object> parameters = new LinkedHashMap<>();
        String condition = "";
        if (searched) {
            String departmentName = DepartmentSearchSql.name("department.name");
            String[] fields = {"employee.full_name", "employee.code", departmentName};
            condition = " AND " + KeywordSearch.nativeCondition(search, "employeeSearch", fields);
            KeywordSearch.bindNative(parameters, search, "employeeSearch");
            parameters.put("identityPhrase", KeywordSearch.phrase(search));
            parameters.put("identityPrefix", KeywordSearch.prefixPattern(KeywordSearch.phrase(search)));
            parameters.put("identityContains", KeywordSearch.containsPattern(KeywordSearch.phrase(search)));
            secondaryOrder = "CASE WHEN " + identity("lower(btrim(%s))=:identityPhrase")
                    + " THEN 0 WHEN " + identity("lower(%s) LIKE :identityPrefix ESCAPE '\\'")
                    + " THEN 1 WHEN " + identity("lower(%s) LIKE :identityContains ESCAPE '\\'")
                    + " THEN 2 ELSE 3 END, " + secondaryOrder;
        }
        var narrowing = EmployeeCandidateFilter.of(departmentId, includeSubtree, List.of(), "employee.id", "employee.department_id");
        parameters.putAll(narrowing.parameters());
        return new Plan(DepartmentSearchSql.prefix(searched), from + DepartmentSearchSql.joins(searched, "employee.department_id")
                + where + condition + narrowing.sql(), secondaryOrder, parameters);
    }

    private static String identity(String pattern) {
        return "(" + String.join(" OR ", Arrays.stream(IDENTITY).map(pattern::formatted).toList()) + ")";
    }

    private <T> PageResponse<T> page(Plan plan, String projection, RowMapper<T> mapper, int page, int size) {
        Pageable pageable = Pageables.of(page, size);
        var rows = rows(plan, projection, mapper, pageable.getPageSize(), pageable.getOffset());
        var result = PageableExecutionUtils.getPage(rows, pageable, () -> {
            Long total = jdbc.queryForObject(plan.prefix() + "SELECT count(*) " + plan.fromWhere(), plan.parameters(), Long.class);
            return total == null ? 0 : total;
        });
        return new PageResponse<>(rows, result);
    }

    private <T> List<T> rows(Plan plan, String projection, RowMapper<T> mapper, int size, long offset) {
        var parameters = new LinkedHashMap<>(plan.parameters());
        parameters.put("candidateLimit", size); parameters.put("candidateOffset", offset);
        return jdbc.query(plan.prefix() + projection + plan.fromWhere() + "\n ORDER BY " + plan.ordering()
                + " LIMIT :candidateLimit OFFSET :candidateOffset", parameters, mapper);
    }

    private record Plan(String prefix, String fromWhere, String ordering, Map<String, Object> parameters) { }
}
