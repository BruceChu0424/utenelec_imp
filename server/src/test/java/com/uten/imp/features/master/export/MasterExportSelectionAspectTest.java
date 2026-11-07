package com.uten.imp.features.master.export;

import com.uten.imp.audit.*;
import com.uten.imp.common.export.*;
import com.uten.imp.features.master.unit.*;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.springframework.aop.aspectj.annotation.AspectJProxyFactory;
import java.util.*;
import java.util.function.Supplier;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class MasterExportSelectionAspectTest {
    @Test void realUnitControllerExportBindsSelectionAndCleansScopeOnFailure() {
        var service = mock(UnitService.class); var user = mock(SecurityContextCurrentUser.class);
        var writer = mock(XlsxExportService.class);
        when(writer.buildSource(any(),isNull(),eq("master_unit"))).thenAnswer(call ->
                new XlsxExportService.SourceWorkbook(call.<Supplier<ExportPayload>>getArgument(0).get(),new byte[0]));
        var target = new UnitController(service, mock(AuditDetailViewRecorder.class), writer,
                mock(WorkbookDownloadService.class), mock(AuditService.class), user);
        var factory = new AspectJProxyFactory(target); factory.addAspect(new MasterExportSelectionAspect());
        UnitController controller = factory.getProxy(); UUID id = UUID.randomUUID();
        when(service.export(any())).thenAnswer(call -> {
            assertThat(MasterExportSelection.current()).containsExactly(id);
            throw new IllegalStateException("fixture generation failure");
        });
        assertThatThrownBy(() -> controller.export(null, null, null, null, null, null,
                new ExportPasswordRequest(null, null, List.of(id))))
                .isInstanceOf(IllegalStateException.class).hasMessage("fixture generation failure");
        verify(service).export(any());
        assertThat(MasterExportSelection.current()).isNull();
    }
}
