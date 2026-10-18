package com.uten.imp.features.webinquiry;

import com.uten.imp.audit.AuditService;
import com.uten.imp.application.port.EmployeeNameLookupPort;
import com.uten.imp.application.port.WebsiteInquiryClientPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.webinquiry.dto.IngestRequest;
import com.uten.imp.features.webinquiry.dto.StatusUpdateRequest;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/** 官网询盘服务：接收幂等 + 状态机 + 转客户幂等。 */
class WebsiteInquiryServiceTest {

    private WebsiteInquiryRepository repository;
    private WebsiteInquiryClientPort clientPort;
    private EmployeeNameLookupPort employeeNames;
    private SecurityContextCurrentUser currentUser;
    private AuditService audit;
    private WebsiteInquiryService service;

    @BeforeEach
    void setUp() {
        repository = mock(WebsiteInquiryRepository.class);
        clientPort = mock(WebsiteInquiryClientPort.class);
        employeeNames = mock(EmployeeNameLookupPort.class);
        currentUser = mock(SecurityContextCurrentUser.class);
        audit = mock(AuditService.class);
        EntityManager entityManager = mock(EntityManager.class);
        Query sourceLock = mock(Query.class);
        when(entityManager.createNativeQuery(anyString())).thenReturn(sourceLock);
        when(sourceLock.setParameter(anyString(), any())).thenReturn(sourceLock);
        service = new WebsiteInquiryService(
                repository, clientPort, employeeNames, currentUser, audit, entityManager,
                mock(WebsiteInquiryTimelineRepository.class),mock(com.uten.imp.application.port.BusinessEventPublisher.class));

        UUID userId = UUID.randomUUID();
        UUID employeeId = UUID.randomUUID();
        when(currentUser.requireId()).thenReturn(userId);
        when(currentUser.requireEmployeeId()).thenReturn(employeeId);
        when(currentUser.employeeId()).thenReturn(Optional.of(employeeId));
        when(currentUser.get()).thenReturn(Optional.of(
                new AuthUser(userId, employeeId, "sales01", Set.of(), false, true, false)));
    }

    private static IngestRequest ingestRequest(String sourceId) {
        return new IngestRequest(
                sourceId, "Alice", "+86-760-1", "a@example.com", "ACME",
                "EU", "distributor", "BS", "Q7 series", "quotation",
                "5000", "2026-Q4", "email", "Interested in Q7 switches.",
                "contact", "en");
    }

    @Test
    void listScopesAreForwardedBeforePagingAndUnknownScopesAreRejected() {
        when(repository.search(anyString(), anyString(), any(org.springframework.data.domain.Pageable.class)))
                .thenReturn(org.springframework.data.domain.Page.empty());
        for (String scope : new String[]{null, "ACTIVE", "HISTORY", "following"}) service.list(scope, " keyword ", 2, 1);
        ArgumentCaptor<String> scopes = ArgumentCaptor.forClass(String.class);
        ArgumentCaptor<org.springframework.data.domain.Pageable> pages = ArgumentCaptor.forClass(org.springframework.data.domain.Pageable.class);
        org.mockito.Mockito.verify(repository, org.mockito.Mockito.times(4)).search(scopes.capture(), org.mockito.ArgumentMatchers.eq("keyword"), pages.capture());
        assertEquals(java.util.List.of("ACTIVE", "ACTIVE", "HISTORY", "following"), scopes.getAllValues());
        assertTrue(pages.getAllValues().stream().allMatch(page -> page.getPageNumber() == 1 && page.getPageSize() == 1));
        assertEquals(java.util.List.of("receivedAt", "id"), pages.getValue().getSort().stream().map(Sort -> Sort.getProperty()).toList());
        assertEquals(ErrorCode.VALIDATION_FAILED, assertThrows(ApiException.class, () -> service.list("UNKNOWN", null, 1, 20)).getCode());
    }

    @Test
    void ingestCreatesOnceAndRepeatsIdempotently() {
        when(repository.findBySourceId("web-1")).thenReturn(Optional.empty());
        assertTrue(service.ingest(ingestRequest("web-1")));
        verify(repository).saveAndFlush(any(WebsiteInquiry.class));

        when(repository.findBySourceId("web-1")).thenReturn(Optional.of(new WebsiteInquiry()));
        assertFalse(service.ingest(ingestRequest("web-1")));
        verify(repository).saveAndFlush(any(WebsiteInquiry.class)); // 仍只有一次
    }

    @Test
    void convertedInquiryRejectsFurtherStatusChanges() {
        WebsiteInquiry inquiry = new WebsiteInquiry();
        inquiry.setId(UUID.randomUUID());
        inquiry.setStatus("converted");
        when(repository.findById(inquiry.getId())).thenReturn(Optional.of(inquiry));

        ApiException thrown = assertThrows(ApiException.class, () -> service.updateStatus(
                inquiry.getId(), new StatusUpdateRequest("closed", null, null)));
        assertEquals(ErrorCode.CONFLICT, thrown.getCode());
        verify(repository, never()).save(any(WebsiteInquiry.class));
    }

    @Test
    void convertCreatesClientAndStaysIdempotent() {
        WebsiteInquiry inquiry = new WebsiteInquiry();
        inquiry.setId(UUID.randomUUID());
        inquiry.setSourceId("web-9");
        inquiry.setName("Alice");
        inquiry.setCompany("ACME Trading");
        inquiry.setStatus("new");
        when(repository.findById(inquiry.getId())).thenReturn(Optional.of(inquiry));
        UUID clientId = UUID.randomUUID();
        when(clientPort.createFromInquiry(any())).thenReturn(
                new WebsiteInquiryClientPort.CreatedClient(clientId, "ACME Trading"));
        when(clientPort.findName(clientId)).thenReturn(Optional.of("ACME Trading"));

        var detail = service.convert(inquiry.getId());
        assertEquals("converted", detail.status());
        assertEquals(clientId, detail.clientId());
        ArgumentCaptor<WebsiteInquiryClientPort.CreateRequest> request =
                ArgumentCaptor.forClass(WebsiteInquiryClientPort.CreateRequest.class);
        verify(clientPort).createFromInquiry(request.capture());
        assertEquals(currentUser.requireEmployeeId(), request.getValue().ownerEmployeeId());
        assertEquals("web-9", request.getValue().sourceId());
        verify(audit).logCommitted(any(), any(), any(), any(), any(), any());

        // 第二次 convert：直接返回详情，不再新建客户
        service.convert(inquiry.getId());
        verify(clientPort).createFromInquiry(any());
    }

    @Test
    void ingestGuardFailsClosedWithoutConfiguredToken() {
        WebsiteInquiryIngestGuard guard = new WebsiteInquiryIngestGuard("");
        assertFalse(guard.tokenValid("anything"));
        WebsiteInquiryIngestGuard configured = new WebsiteInquiryIngestGuard("secret-token");
        assertFalse(configured.tokenValid("wrong"));
        assertTrue(configured.tokenValid("secret-token"));
    }

    @Test
    void anotherEmployeeCannotOverwriteAClaimOrAppendFollowUps() {
        WebsiteInquiry inquiry=new WebsiteInquiry();
        inquiry.setId(UUID.randomUUID());inquiry.setStatus("following");
        inquiry.setAssigneeEmployeeId(UUID.randomUUID());
        when(repository.findById(inquiry.getId())).thenReturn(Optional.of(inquiry));
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,()->service.updateStatus(inquiry.getId(),
                new StatusUpdateRequest("following",null,true))).getCode());
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,()->service.followUp(inquiry.getId(),
                new com.uten.imp.features.webinquiry.dto.FollowUpRequest("other operator"))).getCode());
        verify(repository,never()).save(any());
    }

    @Test
    void sourceContextRequiresABoundedObject() {
        var old=ingestRequest("invalid-context");
        var request=new IngestRequest(old.sourceId(),old.name(),old.phone(),old.email(),old.company(),old.market(),
                old.customerType(),old.requiredStandard(),old.productInterest(),old.requestType(),old.estimatedQuantity(),
                old.targetSchedule(),old.preferredContact(),old.message(),old.source(),old.locale(),
                com.fasterxml.jackson.databind.node.JsonNodeFactory.instance.arrayNode());
        assertThrows(ApiException.class,()->service.ingest(request));
        verify(repository,never()).saveAndFlush(any());
    }
}
