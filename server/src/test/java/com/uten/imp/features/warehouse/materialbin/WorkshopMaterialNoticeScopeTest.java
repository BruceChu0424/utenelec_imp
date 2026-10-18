package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;

import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class WorkshopMaterialNoticeScopeTest {
    @Test
    void superAdminFlagDoesNotExpandAnotherPersonsWorkshopNotifications() {
        var db=mock(NamedParameterJdbcTemplate.class);
        UUID user=UUID.randomUUID(), employee=UUID.randomUUID(), own=UUID.randomUUID(), other=UUID.randomUUID(), production=UUID.randomUUID();
        when(db.queryForList(contains("FROM users"), anyMap())).thenReturn(List.of(
                Map.of("employee_id", employee, "is_super_admin", true)));
        when(db.queryForList(contains("WITH RECURSIVE production"), anyMap())).thenReturn(List.of(
                Map.of("member_id",own,"id",own,"parent_id",production,"is_production",false),
                Map.of("member_id",own,"id",production,"parent_id",UUID.randomUUID(),"is_production",true)));
        var scope=new WorkshopMaterialScope(db,mock(SecurityContextCurrentUser.class));
        assertThat(scope.canSeeForUser(own,user)).isTrue();
        assertThat(scope.canSeeForUser(other,user)).isFalse();
    }
}
