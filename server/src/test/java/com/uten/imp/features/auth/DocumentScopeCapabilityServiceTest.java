package com.uten.imp.features.auth;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.OwnerVisibility;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class DocumentScopeCapabilityServiceTest {

    private final OwnerVisibility visibility = mock(OwnerVisibility.class);
    private final DocumentScopeCapabilityService service =
            new DocumentScopeCapabilityService(visibility);

    @Test
    void manualVisibleOwnerIsNeverReturnedAsWritable() {
        UUID own = UUID.fromString("00000000-0000-0000-0000-000000000001");
        UUID manualVisible = UUID.fromString("00000000-0000-0000-0000-000000000002");
        when(visibility.evaluate("finance", "finance:view:all"))
                .thenReturn(new OwnerVisibility.OwnerScope(
                        false, Set.of(own, manualVisible), Set.of(own)));

        var result = service.current(" finance ");

        assertEquals("finance", result.scope());
        assertFalse(result.writeAll());
        assertEquals(List.of(own), result.writableOwnerIds());
    }

    @Test
    void explicitAllAuthorityIsReportedAsWriteAll() {
        when(visibility.evaluate("stock_doc", "stock_doc:view:all"))
                .thenReturn(new OwnerVisibility.OwnerScope(true, Set.of(), Set.of()));

        var result = service.current("stock_doc");

        assertTrue(result.writeAll());
        assertTrue(result.writableOwnerIds().isEmpty());
    }

    @Test
    void whitelistUsesFixedAuthorityAndRejectsUnknownScope() {
        when(visibility.evaluate("production_plan", "production_plan:view:all"))
                .thenReturn(new OwnerVisibility.OwnerScope(false, Set.of(), Set.of()));

        service.current("production_plan");

        verify(visibility).evaluate("production_plan", "production_plan:view:all");
        ApiException unknown = assertThrows(
                ApiException.class, () -> service.current("client"));
        assertEquals(ErrorCode.VALIDATION_FAILED, unknown.getCode());
        assertThrows(ApiException.class, () -> service.current("FINANCE"));
        assertThrows(ApiException.class, () -> service.current(null));
    }
}
