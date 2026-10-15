package com.uten.imp.features.admin.serveroperations;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class ServerOperationsWorkbenchBadgeSourcesTest {
    @Test void manuallyCachedUpdateIsOneFactForOperatorsAndZeroForMonitorOnly() {
        var controller=mock(ServerOperationsController.class);var source=new ServerOperationsWorkbenchBadgeSources(controller).sources().getFirst();
        when(controller.status()).thenReturn(status(true,true,true));
        assertThat(source.reader().get().get("updates")).isEqualTo(1L);
        when(controller.status()).thenReturn(status(true,false,true));
        assertThat(source.reader().get().get("updates")).isEqualTo(0L);
        when(controller.status()).thenReturn(status(true,true,false));
        assertThat(source.reader().get().get("updates")).isEqualTo(0L);
    }
    @Test void unavailableHostBecomesAStaleSourceRatherThanInventingZeroUpdates() {
        var controller=mock(ServerOperationsController.class);when(controller.status()).thenReturn(status(false,true,false));
        var source=new ServerOperationsWorkbenchBadgeSources(controller).sources().getFirst();
        assertThatThrownBy(() -> source.reader().get()).isInstanceOf(ApiException.class);
    }
    private static ServerOperationsDto.Status status(boolean available,boolean canUpdate,boolean update) {
        return new ServerOperationsDto.Status(available,true,false,false,"v2.5.17","rev",true,null,"v2.5.18",null,update,"UTC",null,null,canUpdate,false,false);
    }
}
