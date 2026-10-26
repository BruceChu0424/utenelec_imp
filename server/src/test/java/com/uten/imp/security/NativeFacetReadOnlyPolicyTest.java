package com.uten.imp.security;
import com.uten.imp.common.report.NativeFacetRoutes;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import static org.junit.jupiter.api.Assertions.*;

class NativeFacetReadOnlyPolicyTest {
    @Test void impersonationRetainsOnlyTheExactExistingReadContractWithAValidFormMarker() {
        assertEquals(21,NativeFacetRoutes.paths().size());
        for(String path:NativeFacetRoutes.paths()) {
            var request=new MockHttpServletRequest("POST",path);
            request.setContentType("application/x-www-form-urlencoded;charset=UTF-8");
            request.addParameter("__facetField",NativeFacetRoutes.find(path).fields().iterator().next());
            assertTrue(ImpersonationWriteGuardFilter.readOnlyFacetCandidate(request,"POST",path),path);
            assertFalse(ImpersonationWriteGuardFilter.readOnlyFacetCandidate(request,"PUT",path));
            assertFalse(ImpersonationWriteGuardFilter.readOnlyFacetCandidate(request,"POST",path+"-save"));
            request.setParameter("__facetField","not-an-original-column");
            assertFalse(ImpersonationWriteGuardFilter.readOnlyFacetCandidate(request,"POST",path));
            request.setContentType("application/json");
            assertFalse(ImpersonationWriteGuardFilter.readOnlyFacetCandidate(request,"POST",path));
        }
    }
}
