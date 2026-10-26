package com.uten.imp.audit;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import static org.junit.jupiter.api.Assertions.*;

class ControlledReadAuditClassificationTest {
    @Test void onlyTheValidatedServerMarkerClassifiesAReadPostAndItsFailureRemainsAudited() {
        var request=new MockHttpServletRequest("POST","/api/warehouse/quality-results/facets");
        request.addParameter("__facetField","billNo");
        request.addHeader("X-Controlled-Read","true");
        assertFalse(AuditRequestContext.isRead(request));
        AuditRequestContext.markControlledRead(request);
        assertTrue(AuditRequestContext.isRead(request));
        assertTrue(AuditRequestContext.shouldRecordOperation(request,403,true,false));
        assertTrue(AuditRequestContext.shouldRecordOperation(request,422,true,false));
        assertFalse(AuditRequestContext.shouldRecordOperation(request,200,false,false));
    }
}
