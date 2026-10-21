package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;

import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.*;

class WorkshopMaterialPeriodReadTest {
    @Test void openedOnlyBinCanReadEmptyPeriodsWithoutEnablingPeriodicMaterial() {
        var db = mock(NamedParameterJdbcTemplate.class);
        var bin = UUID.randomUUID();
        var workshop = UUID.randomUUID();
        when(db.queryForList(anyString(), eq(Map.of("bin", bin)), eq(UUID.class)))
                .thenReturn(List.of(workshop));
        var bins = mock(WorkshopMaterialBinSupport.class);
        var scope = mock(WorkshopMaterialScope.class);
        var views = mock(WorkshopMaterialPeriodViews.class);
        when(views.ofBin(bin)).thenReturn(List.of());
        var commands = mock(WorkshopMaterialCommandLedger.class);
        var service = new WorkshopMaterialPeriodService(db, bins, commands, scope,
                mock(WorkshopMaterialCountService.class), views, mock(SecurityContextCurrentUser.class),
                new WorkshopBinService(db));

        assertThat(service.list(bin).periods()).isEmpty();
        verify(scope).requireWorkshop(workshop);
        verify(views).ofBin(bin);
        verifyNoInteractions(bins, commands);
    }

    @Test void periodReaderKeepsWorkshopBoundaryForOpenedOnlyBins() {
        var db = mock(NamedParameterJdbcTemplate.class);
        var bin = UUID.randomUUID();
        var workshop = UUID.randomUUID();
        when(db.queryForList(anyString(), eq(Map.of("bin", bin)), eq(UUID.class)))
                .thenReturn(List.of(workshop));
        var scope = mock(WorkshopMaterialScope.class);
        doThrow(new ApiException(ErrorCode.FORBIDDEN, "只能查看和办理本车间的内料仓"))
                .when(scope).requireWorkshop(workshop);
        var views = mock(WorkshopMaterialPeriodViews.class);
        var service = new WorkshopMaterialPeriodService(db, mock(WorkshopMaterialBinSupport.class),
                mock(WorkshopMaterialCommandLedger.class), scope, mock(WorkshopMaterialCountService.class),
                views, mock(SecurityContextCurrentUser.class), new WorkshopBinService(db));

        assertThatThrownBy(() -> service.list(bin)).isInstanceOf(ApiException.class).hasMessageContaining("本车间");
        verifyNoInteractions(views);
    }
}
