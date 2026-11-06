package com.uten.imp.common.web;

import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import static org.junit.jupiter.api.Assertions.*;

class PageMetadataRequestTest {
    @Test void absentParameterPreservesCompletePagesAndExplicitFalseIsStrict() {
        assertTrue(PageMetadataRequest.included(null));
        var request=new MockHttpServletRequest();assertTrue(PageMetadataRequest.included(request));
        request.setParameter("includeMetadata","false");assertFalse(PageMetadataRequest.included(request));
        request.setParameter("includeMetadata","true");assertTrue(PageMetadataRequest.included(request));
        for(String bad:java.util.List.of("","0","omit","null")) {
            request.setParameter("includeMetadata",bad);
            assertEquals(ErrorCode.VALIDATION_FAILED,assertThrows(ApiException.class,()->PageMetadataRequest.included(request)).getCode());
        }
    }
}
