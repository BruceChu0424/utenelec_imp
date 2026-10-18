package com.uten.imp.features.org.employee;

import com.uten.imp.features.org.employee.dto.EmployeeListItem;
import com.uten.imp.responsibility.DataHandoverCandidateService;
import com.uten.imp.responsibility.EmployeeHandoverAuthorization;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;
import org.mockito.ArgumentCaptor;
import org.mockito.ArgumentMatchers;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;

import java.sql.ResultSet;
import java.util.List;
import java.util.UUID;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.RETURNS_SELF;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class EmployeePickerStatusProjectionTest {
    static Stream<Arguments> states() {
        return Stream.of("active", "locked", "disabled", "notProvisioned")
                .flatMap(account -> Stream.of("active", "probation", "onLeave", "resigned")
                        .map(employment -> Arguments.of(account, employment)));
    }

    @ParameterizedTest
    @MethodSource("states")
    void employeeRosterKeepsAccountAndEmploymentStatusIndependent(String account, String employment) throws Exception {
        assertEmployeeMapping(account, employment, false);
    }

    @ParameterizedTest
    @MethodSource("states")
    void similarEmployeeSearchReturnsTheSameIndependentStates(String account, String employment) throws Exception {
        assertEmployeeMapping(account, employment, true);
    }

    @SuppressWarnings("unchecked")
    private void assertEmployeeMapping(String account, String employment, boolean similar) throws Exception {
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        when(jdbc.queryForObject(anyString(), eq(Long.class), any(Object[].class))).thenReturn(1L);
        when(jdbc.query(anyString(), ArgumentMatchers.<RowMapper<EmployeeListItem>>any(), any(Object[].class)))
                .thenReturn(List.of());
        EmployeeListQuery query = new EmployeeListQuery(jdbc);
        if (similar) {
            query.similar("员工", 20);
        } else {
            query.query(1, 20, null, null, null, false, null, null);
        }
        ArgumentCaptor<RowMapper<EmployeeListItem>> mapper = ArgumentCaptor.forClass(RowMapper.class);
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(jdbc).query(sql.capture(), mapper.capture(), any(Object[].class));
        ResultSet row = mock(ResultSet.class);
        when(row.getString("status")).thenReturn(employment);
        when(row.getString("account_status")).thenReturn(account);

        EmployeeListItem item = mapper.getValue().mapRow(row, 0);

        assertThat(item.getAccountStatus()).isEqualTo(account);
        assertThat(item.getStatus()).isEqualTo(employment);
        assertThat(sql.getValue()).contains(
                "LEFT JOIN users account ON account.employee_id = e.id AND account.is_deleted = FALSE",
                "COALESCE(account.status, 'notProvisioned') AS account_status");
        // The account projection must not turn the left join into an active-account candidate filter.
        assertThat(sql.getValue()).doesNotContain("AND account.status = 'active'");
    }

    @ParameterizedTest
    @MethodSource("states")
    void handoverSourcesRetainTheirScopedIdentityAndBothStatuses(String account, String employment) {
        EntityManager em = mock(EntityManager.class);
        Query count = mock(Query.class, RETURNS_SELF);
        Query data = mock(Query.class, RETURNS_SELF);
        when(em.createNativeQuery(anyString())).thenReturn(count, data);
        when(count.getSingleResult()).thenReturn(1L);
        UUID employeeId = UUID.randomUUID();
        UUID departmentId = UUID.randomUUID();
        when(data.getResultList()).thenReturn(List.<Object[]>of(new Object[]{
                employeeId, "UT0001", "员工", departmentId, "部门", employment, account}));
        EmployeeHandoverAuthorization authorization = mock(EmployeeHandoverAuthorization.class);
        when(authorization.candidateScope()).thenReturn(
                new EmployeeHandoverAuthorization.CandidateScope(false, UUID.randomUUID()));

        var page = new DataHandoverCandidateService(em, authorization).search("source", "", 1, 20);

        assertThat(page.items()).hasSize(1);
        var item = page.items().getFirst();
        assertThat(item.employeeId()).isEqualTo(employeeId);
        assertThat(item.departmentId()).isEqualTo(departmentId);
        assertThat(item.accountStatus()).isEqualTo(account);
        assertThat(item.status()).isEqualTo(employment);
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, times(2)).createNativeQuery(sql.capture());
        assertThat(sql.getAllValues()).allSatisfy(statement -> assertThat(statement)
                .contains("manager_root.manager_id=:managerEmployeeId", "protected_account.is_super_admin=true"));
        assertThat(sql.getAllValues().get(1)).contains(
                "LEFT JOIN users account ON account.employee_id=employee.id AND account.is_deleted=false",
                "COALESCE(account.status, 'notProvisioned') AS account_status");
    }

    @Test
    void legacyEmployeeConstructorDoesNotInventAnUnprovisionedAccount() {
        EmployeeListItem legacy = new EmployeeListItem(UUID.randomUUID(), "UT01", "员工", null,
                null, null, "active", null, null, null, false, 0, null, null);
        assertThat(legacy.getAccountStatus()).isNull();
        assertThat(legacy.getStatus()).isEqualTo("active");
    }
}
