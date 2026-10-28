package com.uten.imp.support;

import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.security.OwnerVisibility;
import java.util.Set;
import static org.mockito.Mockito.*;

/** Explicit company-wide read authority for report fixtures; production never falls back to this. */
public final class FinanceReportTestAccess {
    private FinanceReportTestAccess() { }
    public static FinanceDocumentAccessPolicy company() {
        var access=mock(FinanceDocumentAccessPolicy.class);
        when(access.scope()).thenReturn(new OwnerVisibility.OwnerScope(true,Set.of()));
        return access;
    }
}
