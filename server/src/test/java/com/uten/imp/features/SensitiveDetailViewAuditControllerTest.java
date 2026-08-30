package com.uten.imp.features;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.export.WorkbookDownloadService;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.features.admin.UserAccountAdminService;
import com.uten.imp.features.master.account.AccountController;
import com.uten.imp.features.master.account.AccountService;
import com.uten.imp.features.master.account.dto.AccountDetail;
import com.uten.imp.features.master.client.ClientController;
import com.uten.imp.features.master.client.ClientService;
import com.uten.imp.features.master.client.dto.ClientDetail;
import com.uten.imp.features.master.supplier.SupplierController;
import com.uten.imp.features.master.supplier.SupplierService;
import com.uten.imp.features.master.supplier.dto.SupplierDetail;
import com.uten.imp.features.org.employee.EmployeeCommandService;
import com.uten.imp.features.org.employee.EmployeeController;
import com.uten.imp.features.org.employee.EmployeeOnboardingService;
import com.uten.imp.features.org.employee.EmployeeQueryService;
import com.uten.imp.features.org.employee.dto.EmployeeDetail;
import com.uten.imp.features.visitor.VisitorApprovalController;
import com.uten.imp.features.visitor.VisitorHostConfirmService;
import com.uten.imp.features.visitor.VisitorHrApprovalService;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorDetail;
import com.uten.imp.features.webinquiry.WebsiteInquiryController;
import com.uten.imp.features.webinquiry.WebsiteInquiryIngestGuard;
import com.uten.imp.features.webinquiry.WebsiteInquiryService;
import com.uten.imp.features.webinquiry.dto.WebsiteInquiryDetail;
import com.uten.imp.responsibility.DataHandoverService;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class SensitiveDetailViewAuditControllerTest {

    @Test
    void successfulSensitiveDetailsRecordOnlySafeBusinessReferences() {
        AuditDetailViewRecorder audit = mock(AuditDetailViewRecorder.class);

        UUID employeeId = UUID.randomUUID();
        EmployeeQueryService employees = mock(EmployeeQueryService.class);
        EmployeeDetail employee = mock(EmployeeDetail.class);
        when(employee.getCode()).thenReturn("E-001");
        when(employees.detail(employeeId)).thenReturn(employee);
        EmployeeController employeeController = new EmployeeController(
                employees,
                mock(EmployeeOnboardingService.class),
                mock(EmployeeCommandService.class),
                mock(UserAccountAdminService.class),
                mock(DataHandoverService.class),
                audit);
        assertSame(employee, employeeController.detail(employeeId));
        verify(audit).record(
                "view_employee_detail", "employees", employeeId,
                "E-001", null, "员工档案");

        UUID visitorId = UUID.randomUUID();
        VisitorHrApprovalService visitors = mock(VisitorHrApprovalService.class);
        VisitorDetail visitor = mock(VisitorDetail.class);
        when(visitor.visitorName()).thenReturn("来访人员甲");
        when(visitors.getDetailForStaff(visitorId)).thenReturn(visitor);
        VisitorApprovalController visitorController = new VisitorApprovalController(
                visitors, mock(VisitorHostConfirmService.class), audit);
        assertSame(visitor, visitorController.detail(visitorId));
        verify(audit).record(
                "view_visitor_application_detail", "visitor_applications", visitorId,
                "来访人员甲", null, "访客申请");

        UUID inquiryId = UUID.randomUUID();
        WebsiteInquiryService inquiries = mock(WebsiteInquiryService.class);
        WebsiteInquiryDetail inquiry = mock(WebsiteInquiryDetail.class);
        when(inquiry.sourceId()).thenReturn("WEB-001");
        when(inquiries.detail(inquiryId)).thenReturn(inquiry);
        WebsiteInquiryController inquiryController = new WebsiteInquiryController(
                inquiries, mock(WebsiteInquiryIngestGuard.class), audit);
        assertSame(inquiry, inquiryController.detail(inquiryId));
        verify(audit).record(
                "view_website_inquiry_detail", "website_inquiries", inquiryId,
                "WEB-001", null, "官网询盘");

        UUID clientId = UUID.randomUUID();
        ClientService clients = mock(ClientService.class);
        ClientDetail client = mock(ClientDetail.class);
        when(client.getCode()).thenReturn("C-001");
        when(client.getLegacyId()).thenReturn(11);
        when(clients.detail(clientId)).thenReturn(client);
        ClientController clientController = new ClientController(
                clients,
                mock(XlsxExportService.class),
                mock(WorkbookDownloadService.class),
                mock(com.uten.imp.audit.AuditService.class),
                audit,
                mock(SecurityContextCurrentUser.class));
        assertSame(client, clientController.detail(clientId));
        verify(audit).record(
                "view_client_detail", "clients", clientId,
                "C-001", 11, "客户档案");

        UUID supplierId = UUID.randomUUID();
        SupplierService suppliers = mock(SupplierService.class);
        SupplierDetail supplier = mock(SupplierDetail.class);
        when(supplier.getCode()).thenReturn("S-001");
        when(supplier.getLegacyId()).thenReturn(22);
        when(suppliers.detail(supplierId)).thenReturn(supplier);
        SupplierController supplierController = new SupplierController(
                suppliers,
                mock(XlsxExportService.class),
                mock(WorkbookDownloadService.class),
                mock(com.uten.imp.audit.AuditService.class),
                audit,
                mock(SecurityContextCurrentUser.class));
        assertSame(supplier, supplierController.detail(supplierId));
        verify(audit).record(
                "view_supplier_detail", "suppliers", supplierId,
                "S-001", 22, "供应商档案");

        UUID accountId = UUID.randomUUID();
        AccountService accounts = mock(AccountService.class);
        AccountDetail account = mock(AccountDetail.class);
        when(account.getCode()).thenReturn("A-001");
        when(account.getLegacyId()).thenReturn(33);
        when(accounts.detail(accountId)).thenReturn(account);
        AccountController accountController = new AccountController(
                accounts,
                mock(XlsxExportService.class),
                mock(WorkbookDownloadService.class),
                mock(com.uten.imp.audit.AuditService.class),
                audit,
                mock(SecurityContextCurrentUser.class));
        assertSame(account, accountController.detail(accountId));
        verify(audit).record(
                "view_account_detail", "accounts", accountId,
                "A-001", 33, "资金账户");
    }

    @Test
    void failedSensitiveDetailNeverWritesSuccessfulViewEvent() {
        AuditDetailViewRecorder audit = mock(AuditDetailViewRecorder.class);
        WebsiteInquiryService service = mock(WebsiteInquiryService.class);
        UUID id = UUID.randomUUID();
        RuntimeException denied = new RuntimeException("detail denied");
        when(service.detail(id)).thenThrow(denied);
        WebsiteInquiryController controller = new WebsiteInquiryController(
                service, mock(WebsiteInquiryIngestGuard.class), audit);

        assertSame(denied, assertThrows(RuntimeException.class, () -> controller.detail(id)));
        verifyNoInteractions(audit);
    }
}
