package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.application.port.WarehouseTaskScopePort;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;

import java.util.Map;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class WorkshopMaterialBadgePermissionTest {
    @Test void viewingOrRequestingMaterialDoesNotCreateWarehouseIssueTasks() {
        var db = mock(NamedParameterJdbcTemplate.class);
        var permissions = mock(WorkshopMaterialPermissions.class);
        var service = new WorkshopMaterialPositionQueryService(db, null, null, permissions, null, null);
        var counts = service.badgeCounts(WarehouseTaskScopePort.WarehouseTaskScope.ALL);
        assertThat(counts.pendingIssue()).isZero();
        assertThat(counts.pendingReturn()).isZero();
        assertThat(counts.counting()).isZero();
        verifyNoInteractions(db);
    }

    @Test void issuingAndCountingAreIndependentEvenWhenBothTypesOfWorkExist() {
        var db = mock(NamedParameterJdbcTemplate.class);
        var permissions = mock(WorkshopMaterialPermissions.class);
        var scope = mock(WorkshopMaterialScope.class);
        when(scope.predicate(anyString(), any())).thenReturn("TRUE");
        when(scope.requisitionWarehouseFilter(any(), any())).thenReturn("");
        when(db.queryForMap(anyString(), any(MapSqlParameterSource.class)))
                .thenReturn(Map.of("pending_issue", 2L, "pending_return", 3L, "counting", 4L));
        var service = new WorkshopMaterialPositionQueryService(db, null, scope, permissions, null, null);
        when(permissions.has(WorkshopMaterialPermissions.ISSUE)).thenReturn(true);
        var issuer = service.badgeCounts(WarehouseTaskScopePort.WarehouseTaskScope.ALL);
        assertThat(issuer.pendingIssue()).isEqualTo(2);
        assertThat(issuer.pendingReturn()).isEqualTo(3);
        assertThat(issuer.counting()).isZero();
        when(permissions.has(WorkshopMaterialPermissions.ISSUE)).thenReturn(false);
        when(permissions.has(WorkshopMaterialPermissions.COUNT)).thenReturn(true);
        var counter = service.badgeCounts(WarehouseTaskScopePort.WarehouseTaskScope.ALL);
        assertThat(counter.pendingIssue()).isZero();
        assertThat(counter.pendingReturn()).isZero();
        assertThat(counter.counting()).isEqualTo(4);
    }
}
