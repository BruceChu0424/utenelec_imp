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
        service = new WebsiteInquiryService(
                repository, clientPort, employeeNames, currentUser, audit);

        UUID userId = UUID.randomUUID();
        UUID employeeId = UUID.randomUUID();
        when(currentUser.requireId()).thenReturn(userId);
        when(currentUser.requireEmployeeId()).thenReturn(employeeId);
        when(currentUser.employeeId()).thenReturn(Optional.of(employeeId));
        when(currentUser.get()).thenReturn(Optional.of(
                new AuthUser(userId, employeeId, "sales01",
                        Set.of(), Set.of(), false, true, false)));
    }

    private static IngestRequest ingestRequest(String sourceId) {
        return new IngestRequest(
                sourceId, "Alice", "+86-760-1", "a@example.com", "ACME",
                "EU", "distributor", "BS", "Q7 series", "quotation",
                "5000", "2026-Q4", "email", "Interested in Q7 switches.",
                "contact", "en");
    }

    @Test
    void ingestCreatesOnceAndRepeatsIdempotently() {
        when(repository.findBySourceId("web-1")).thenReturn(Optional.empty());
        assertTrue(service.ingest(ingestRequest("web-1")));
        verify(repository).save(any(WebsiteInquiry.class));

        when(repository.findBySourceId("web-1")).thenReturn(Optional.of(new WebsiteInquiry()));
        assertFalse(service.ingest(ingestRequest("web-1")));
        verify(repository).save(any(WebsiteInquiry.class)); // 仍只有一次
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
}
