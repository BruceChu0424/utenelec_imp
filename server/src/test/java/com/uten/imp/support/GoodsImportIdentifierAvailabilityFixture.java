package com.uten.imp.support;

import com.uten.imp.common.mastercode.MasterIdentifierAvailabilityService;
import com.uten.imp.features.master.goods.importing.GoodsImportService;
import org.springframework.test.util.ReflectionTestUtils;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** Keeps unrelated import unit fixtures independent of the database identifier registry. */
public final class GoodsImportIdentifierAvailabilityFixture {
    private GoodsImportIdentifierAvailabilityFixture() { }

    public static GoodsImportService allowAll(GoodsImportService importer) {
        var availability = mock(MasterIdentifierAvailabilityService.class);
        when(availability.checkForTargetCategory(any(), anyString(), any(), any())).thenAnswer(invocation ->
                new MasterIdentifierAvailabilityService.Availability(invocation.getArgument(1), true, null));
        when(availability.checkForRestore(any(), anyString(), any(), any())).thenAnswer(invocation ->
                new MasterIdentifierAvailabilityService.Availability(invocation.getArgument(1), true, null));
        ReflectionTestUtils.setField(importer, "identifierAvailability", availability);
        return importer;
    }
}
