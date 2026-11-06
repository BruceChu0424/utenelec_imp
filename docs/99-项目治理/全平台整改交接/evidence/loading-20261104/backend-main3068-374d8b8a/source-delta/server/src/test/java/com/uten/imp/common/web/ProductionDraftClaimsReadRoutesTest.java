package com.uten.imp.common.web;

import com.uten.imp.common.report.NativeTaskReadScopeInterceptor;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class ProductionDraftClaimsReadRoutesTest {
    @Test void onlyTheExactControlledReadBodyGetsTheOriginalReportOwnerPublicationProfile() {
        String path="/api/production/daily-reports/draft-claims/query";
        assertTrue(ExactBodyReadRoutes.matches("POST",path));
        assertEquals("native_production_owner",NativeTaskReadScopeInterceptor.profile(path));
        for(String adjacent:new String[]{path+"/save",path+"/",path.replace("/query","/approve"),
                "/api/production/daily-reports","/api/production/daily-reports/create-receipt"}) {
            assertFalse(ExactBodyReadRoutes.matches("POST",adjacent));
        }
        assertFalse(ExactBodyReadRoutes.matches("PUT",path));
    }
}
