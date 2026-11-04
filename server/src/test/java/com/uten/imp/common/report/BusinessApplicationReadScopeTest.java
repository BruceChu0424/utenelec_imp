package com.uten.imp.common.report;
import com.uten.imp.common.web.*;
import com.uten.imp.security.*;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.http.server.*;
import org.springframework.mock.web.*;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;
class BusinessApplicationReadScopeTest {
    @Test void applicationQueuesAndDetailsRejectLatePublicationAfterEmployeeApprovalScopeChanges(){
        for(String suffix:List.of("mine","pending","history","counts","prepayment-posting",UUID.randomUUID().toString())){
            var subject=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"fixture",Set.of("application:approve:department"),false,true,false);
            var authority=mock(ReadScopeVersionAuthority.class);var current=mock(SecurityContextCurrentUser.class);
            when(current.get()).thenReturn(Optional.of(subject));when(authority.scopeFor("expense",subject)).thenReturn("before","after");
            var request=new MockHttpServletRequest("GET","/api/business-applications/"+suffix);var response=new MockHttpServletResponse();
            new BusinessDocumentReadScopeInterceptor(authority,current).preHandle(request,response,null);
            var error=assertThrows(ApiException.class,()->new ReportReadScopeAdvice(authority).beforeBodyWrite(Map.of("items",List.of("late")),null,MediaType.APPLICATION_JSON,null,new ServletServerHttpRequest(request),new ServletServerHttpResponse(response)));
            assertEquals(ErrorCode.READ_SCOPE_CHANGED,error.getCode());assertNull(response.getHeader(ReadScopePublication.HEADER));
        }
    }
    @Test void classifiedFinancialCandidatesKeepTheFinanceOwnerProofUntilPublication(){
        var subject=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"fixture",Set.of("application:prepayment:link_finance","finance_payment:view"),false,true,false);
        var authority=mock(ReadScopeVersionAuthority.class);var current=mock(SecurityContextCurrentUser.class);
        when(current.get()).thenReturn(Optional.of(subject));when(authority.scopeFor("finance",subject)).thenReturn("before","after");
        var request=new MockHttpServletRequest("GET","/api/business-applications/"+UUID.randomUUID()+"/prepayment-finance-candidates");var response=new MockHttpServletResponse();
        new BusinessDocumentReadScopeInterceptor(authority,current).preHandle(request,response,null);
        var error=assertThrows(ApiException.class,()->new ReportReadScopeAdvice(authority).beforeBodyWrite(Map.of("items",List.of("late financial source")),null,MediaType.APPLICATION_JSON,null,new ServletServerHttpRequest(request),new ServletServerHttpResponse(response)));
        assertEquals(ErrorCode.READ_SCOPE_CHANGED,error.getCode());verify(authority,never()).scopeFor("expense",subject);
    }
    @Test void applicationCommandsAreNeverConvertedIntoAutomaticReadReplays(){
        var authority=mock(ReadScopeVersionAuthority.class);var current=mock(SecurityContextCurrentUser.class);
        var request=new MockHttpServletRequest("POST","/api/business-applications/"+UUID.randomUUID()+"/approve");
        new BusinessDocumentReadScopeInterceptor(authority,current).preHandle(request,new MockHttpServletResponse(),null);
        verifyNoInteractions(authority,current);assertNull(request.getAttribute(ReadScopePublication.ATTRIBUTE));
    }
}
