package com.uten.imp.security;

import org.junit.jupiter.api.Test;
import java.util.List;
import static org.junit.jupiter.api.Assertions.*;

class DailyCreateReceiptReadOnlyRouteContractTest {
    @Test void onlyExactDailyCreateReceiptPostIsWhitelisted() {
        String path="/api/production/daily-reports/create-receipt";
        assertTrue(ImpersonationWriteGuardFilter.readOnlyDailyCreateReceipt("POST",path));
        for(String method:List.of("GET","PUT","PATCH","DELETE")) {
            assertFalse(ImpersonationWriteGuardFilter.readOnlyDailyCreateReceipt(method,path));
        }
        for(String other:List.of("/api/production/daily-reports",path+"/",path+"/approve",
                path+"/../create","/api/production/daily-reports/approval-receipt","/api/stock/docs/create-receipt")) {
            assertFalse(ImpersonationWriteGuardFilter.readOnlyDailyCreateReceipt("POST",other));
        }
    }
}
