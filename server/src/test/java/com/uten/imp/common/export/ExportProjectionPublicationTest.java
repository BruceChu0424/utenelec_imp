package com.uten.imp.common.export;

import com.uten.imp.common.platformcolumns.PlatformColumnContracts.*;
import com.uten.imp.common.platformcolumns.PlatformColumnService;
import com.uten.imp.common.report.LegacyExportReadScopeInterceptor;
import com.uten.imp.common.report.ReportReadScopeAdvice;
import com.uten.imp.common.web.*;
import com.uten.imp.security.*;
import org.junit.jupiter.api.*;
import org.mockito.ArgumentCaptor;
import org.springframework.aop.framework.ProxyFactory;
import org.springframework.http.MediaType;
import org.springframework.http.converter.ByteArrayHttpMessageConverter;
import org.springframework.http.server.*;
import org.springframework.mock.web.*;
import org.springframework.transaction.*;
import org.springframework.transaction.annotation.AnnotationTransactionAttributeSource;
import org.springframework.transaction.interceptor.TransactionInterceptor;
import org.springframework.transaction.support.SimpleTransactionStatus;
import org.springframework.web.context.request.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicBoolean;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ExportProjectionPublicationTest {
    @AfterEach void clear(){RequestContextHolder.resetRequestAttributes();}
    @Test void revokedDefinitionAclAfterBridgeProjectionPublishesZeroBytesAndPreservesTheFailure() throws Exception { rejects(true); }
    @Test void deletedDefinitionAfterBridgeProjectionPublishesZeroBytesAndWorkersRecordNothing() throws Exception { rejects(false); }

    private void rejects(boolean revoked) throws Exception {
        UUID id=UUID.randomUUID();var available=new AtomicBoolean(true);
        var definition=new Definition(id,"view_sales","Private column","TEXT",false,null,0,0);
        var platform=mock(PlatformColumnService.class);
        when(platform.definitionsByIds(eq("view_sales"),eq(List.of(id)))).thenAnswer(ignored->{
            if(available.get())return List.of(definition);
            if(revoked)throw new ApiException(ErrorCode.FORBIDDEN,"Definition ACL revoked");
            return List.of();
        });
        when(platform.evaluateDisplayRows(eq("view_sales"),eq(List.of(id)),anyList())).thenReturn(List.of(Map.of(id,"private value")));
        var projections=new ExportTableProjectionService(platform);
        var columns=new ArrayList<TableColumnProjection.Column>();
        columns.add(new TableColumnProjection.Column("platform:"+id,"untrusted label",120d,"text",null));
        var selected=new TableColumnProjection("client supplied","view_sales",columns);
        // A durable worker has no HTTP request; it cannot leave publication state.
        projections.project(List.of(),List.of(),selected,"view_sales");
        var request=new MockHttpServletRequest("POST","/api/sales/reports/export");
        request.addHeader("X-Export-Projection","platform:"+UUID.randomUUID());
        assertThat(Collections.list(request.getAttributeNames())).isEmpty();
        var response=new MockHttpServletResponse();
        RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(request));
        var authority=mock(ReadScopeVersionAuthority.class);var users=mock(SecurityContextCurrentUser.class);
        var subject=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"unchanged reader",Set.of("sales_report:export"),false,true,false);
        when(users.get()).thenReturn(Optional.of(subject));when(authority.scopeFor("sales",subject)).thenReturn("a".repeat(64));
        new LegacyExportReadScopeInterceptor(authority,users).preHandle(request,response,null);
        var transactions=mock(PlatformTransactionManager.class);
        when(transactions.getTransaction(any())).thenReturn(new SimpleTransactionStatus());
        var proxy=new ProxyFactory(new ExportProjectionAccessGuard(platform));
        proxy.addAdvice(new TransactionInterceptor(transactions,new AnnotationTransactionAttributeSource()));
        var guard=(ExportProjectionAccessGuard)proxy.getProxy();var advice=new ReportReadScopeAdvice(authority,guard);
        // The bridge uses a document sink, where LegacyExportBudget.active() is false.
        try(var sink=DocumentPageSink.open(new DocumentPageSink.Consumer(){public void begin(DocumentPageSink.Header h){}public void accept(DocumentPageSink.Page p){}})) {
            assertThat(LegacyExportBudget.active()).isFalse();
            projections.project(List.of(),List.of(),selected,"view_sales");
            projections.project(List.of(),List.of(Map.of()),selected,"view_sales");
        }
        columns.clear(); // Request-owned projection IDs must already be frozen.
        available.set(false);
        byte[] secret="private exported bytes".getBytes(java.nio.charset.StandardCharsets.UTF_8);
        var servletRequest=new ServletServerHttpRequest(request);var servletResponse=new ServletServerHttpResponse(response);
        var failure=catchThrowableOfType(()->{
            var body=(byte[])advice.beforeBodyWrite(secret,null,MediaType.APPLICATION_OCTET_STREAM,ByteArrayHttpMessageConverter.class,servletRequest,servletResponse);
            new ByteArrayHttpMessageConverter().write(body,MediaType.APPLICATION_OCTET_STREAM,servletResponse);
        },ApiException.class);
        assertThat(failure.getCode()).isEqualTo(revoked?ErrorCode.FORBIDDEN:ErrorCode.CONFLICT);
        assertThat(response.getContentAsByteArray()).isEmpty();assertThat(response.getHeader("X-Uten-Read-Scope-Version")).isNull();
        var tx=ArgumentCaptor.forClass(TransactionDefinition.class);verify(transactions).getTransaction(tx.capture());
        assertThat(tx.getValue().getPropagationBehavior()).isEqualTo(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        verify(platform,times(4)).definitionsByIds("view_sales",List.of(id)); // worker + two pages + one publication
        response.setStatus(revoked?403:409);var error=Map.of("code",failure.getCode().name());
        assertThat(advice.beforeBodyWrite(error,null,MediaType.APPLICATION_JSON,null,servletRequest,servletResponse)).isSameAs(error);
        verify(transactions,times(1)).getTransaction(any());verify(authority,times(2)).scopeFor("sales",subject);
    }
}
