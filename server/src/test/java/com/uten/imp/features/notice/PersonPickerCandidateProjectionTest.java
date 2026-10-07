package com.uten.imp.features.notice;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.warehouse.WarehouseKeeperService;
import com.uten.imp.features.master.warehouse.dto.WarehouseKeeper;
import com.uten.imp.features.notice.dto.NoticeAudienceEmployeeDto;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.simple.JdbcClient;

import java.sql.ResultSet;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.RETURNS_SELF;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class PersonPickerCandidateProjectionTest {

    @Test
    void noticeCandidatesReturnDepartmentIdentityAndDoNotTruncateAtOneHundred() throws Exception {
        Fixture fixture = new Fixture();
        NoticeAudienceEmployeeDto candidate = new NoticeAudienceEmployeeDto(
                UUID.randomUUID().toString(), "员工", "UT01", UUID.randomUUID().toString(), "销售组");
        fixture.rows(Collections.nCopies(121, candidate));

        var result = new NoticeAudienceService(fixture.jdbc).searchEmployees(null);

        assertThat(result).hasSize(121);
        var mapped = fixture.<NoticeAudienceEmployeeDto>mapRow();
        assertThat(mapped.departmentId()).isEqualTo(fixture.departmentId.toString());
        assertThat(mapped.departmentName()).isEqualTo("同名部门");
        assertThat(fixture.sql()).contains("u.status = 'active'", "e.is_deleted = false");
        verify(fixture.statement).param("limit", 5001);
    }

    @Test
    void warehouseCandidatesPreserveNoAccountEmployeesAndTheirDepartment() throws Exception {
        Fixture fixture = new Fixture();
        WarehouseKeeper candidate = new WarehouseKeeper(
                UUID.randomUUID(), "员工", "UT01", UUID.randomUUID(), "销售组", false, false, true);
        fixture.rows(Collections.nCopies(75, candidate));

        var result = fixture.warehouses().candidates(null);

        assertThat(result).hasSize(75).allSatisfy(row -> assertThat(row.hasAccount()).isFalse());
        var mapped = fixture.<WarehouseKeeper>mapRow();
        assertThat(mapped.departmentId()).isEqualTo(fixture.departmentId);
        assertThat(mapped.departmentName()).isEqualTo("同名部门");
        assertThat(mapped.hasAccount()).isFalse();
        assertThat(fixture.sql()).contains("e.status <> 'resigned'", "LIMIT 5001")
                .doesNotContain("LIMIT 50\n");
    }

    @Test
    void oversizedNoticeDirectoryFailsExplicitlyInsteadOfReturningAPartialDepartmentList() {
        Fixture fixture = new Fixture();
        fixture.rows(Collections.nCopies(5001, new NoticeAudienceEmployeeDto("e", "员工", "UT01", null, null)));
        assertThatThrownBy(() -> new NoticeAudienceService(fixture.jdbc).searchEmployees(null))
                .isInstanceOf(ApiException.class).hasMessageContaining("缩小范围");
    }

    @Test
    void oversizedWarehouseDirectoryFailsExplicitlyInsteadOfReturningAPartialDepartmentList() {
        Fixture fixture = new Fixture();
        fixture.rows(Collections.nCopies(5001, new WarehouseKeeper(
                UUID.randomUUID(), "员工", "UT01", null, null, true, true, false)));
        assertThatThrownBy(() -> fixture.warehouses().candidates(null))
                .isInstanceOf(ApiException.class).hasMessageContaining("缩小范围");
    }

    @SuppressWarnings({"rawtypes", "unchecked"})
    private static final class Fixture {
        final JdbcClient jdbc = mock(JdbcClient.class);
        final JdbcClient.StatementSpec statement = mock(JdbcClient.StatementSpec.class, RETURNS_SELF);
        final JdbcClient.MappedQuerySpec query = mock(JdbcClient.MappedQuerySpec.class);
        final UUID departmentId = UUID.randomUUID();

        Fixture() {
            when(jdbc.sql(anyString())).thenReturn(statement);
            when(statement.query(any(RowMapper.class))).thenReturn(query);
        }

        void rows(List<?> rows) { when(query.list()).thenReturn(rows); }

        WarehouseKeeperService warehouses() {
            return new WarehouseKeeperService(jdbc, mock(TxSessionVars.class), mock(SecurityContextCurrentUser.class));
        }

        <T> T mapRow() throws Exception {
            ArgumentCaptor<RowMapper> mapper = ArgumentCaptor.forClass(RowMapper.class);
            verify(statement).query(mapper.capture());
            ResultSet row = mock(ResultSet.class);
            when(row.getObject("id", UUID.class)).thenReturn(UUID.randomUUID());
            when(row.getObject("department_id", UUID.class)).thenReturn(departmentId);
            when(row.getString("department_id")).thenReturn(departmentId.toString());
            when(row.getString("department_name")).thenReturn("同名部门");
            return (T) mapper.getValue().mapRow(row, 0);
        }

        String sql() {
            ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
            verify(jdbc).sql(sql.capture());
            return sql.getValue();
        }
    }
}
