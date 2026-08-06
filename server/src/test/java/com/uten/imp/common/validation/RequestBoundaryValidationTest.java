package com.uten.imp.common.validation;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.EncryptedWorkbookService;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.GlobalExceptionHandler;
import com.uten.imp.features.admin.AdminUserController;
import com.uten.imp.features.admin.DataScopeAdminService;
import com.uten.imp.features.admin.PermissionOverrideAdminService;
import com.uten.imp.features.admin.RoleAdminService;
import com.uten.imp.features.admin.UserAccountAdminService;
import com.uten.imp.features.admin.dto.DepartmentPermissionsDto;
import com.uten.imp.features.admin.dto.PermissionOverridesDto;
import com.uten.imp.features.master.goods.GoodsController;
import com.uten.imp.features.master.goods.GoodsService;
import com.uten.imp.features.notice.NoticeController;
import com.uten.imp.features.notice.NoticeService;
import com.uten.imp.features.notice.dto.NoticeAudienceRequest;
import com.uten.imp.features.notice.dto.NoticeBatchDeleteRequest;
import com.uten.imp.features.notice.dto.NoticePublishRequest;
import com.uten.imp.features.org.employee.dto.OnboardingRequest;
import com.uten.imp.features.org.employee.dto.UpdateEmployeeRequest;
import com.uten.imp.features.production.schedule.ProductionScheduleController;
import com.uten.imp.features.production.schedule.ProductionScheduleService;
import com.uten.imp.features.profilechange.ProfileChangeController;
import com.uten.imp.features.profilechange.ProfileChangeQueryService;
import com.uten.imp.features.profilechange.ProfileChangeReviewService;
import com.uten.imp.features.profilechange.ProfileChangeSubmitService;
import com.uten.imp.features.profilechange.dto.ProfileChangeDto;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.validation.Validation;
import jakarta.validation.Validator;
import jakarta.validation.constraints.Size;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.lang.reflect.Field;
import java.lang.reflect.RecordComponent;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

class RequestBoundaryValidationTest {

    private final Validator validator = Validation
            .buildDefaultValidatorFactory()
            .getValidator();

    @Test
    void everyTransactionCollectionRejectsMoreThanDocumentLimit() throws Exception {
        List<Target> targets = List.of(
                new Target(com.uten.imp.features.finance.bank_transfer.dto.FinanceBankTransferSaveRequest.class, "items"),
                new Target(com.uten.imp.features.finance.expense.dto.FinanceExpenseSaveRequest.class, "items"),
                new Target(com.uten.imp.features.finance.other_income.dto.FinanceOtherIncomeSaveRequest.class, "items"),
                new Target(com.uten.imp.features.finance.payment.dto.FinancePaymentSaveRequest.class, "items"),
                new Target(com.uten.imp.features.finance.receipt.dto.FinanceReceiptSaveRequest.class, "items"),
                new Target(com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest.class, "items"),
                new Target(com.uten.imp.features.production.plan.dto.PlanSaveRequest.class, "items"),
                new Target(com.uten.imp.features.purchase.order.dto.OrderSaveRequest.class, "items"),
                new Target(com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest.class, "items"),
                new Target(com.uten.imp.features.purchase.request.dto.RequestSaveRequest.class, "items"),
                new Target(com.uten.imp.features.purchase.ret.dto.ReturnSaveRequest.class, "items"),
                new Target(com.uten.imp.features.sales.order.dto.OrderSaveRequest.class, "items"),
                new Target(com.uten.imp.features.sales.other_shipment.dto.OtherShipmentSaveRequest.class, "items"),
                new Target(com.uten.imp.features.sales.quote.dto.QuoteSaveRequest.class, "items"),
                new Target(com.uten.imp.features.sales.ret.dto.ReturnSaveRequest.class, "items"),
                new Target(com.uten.imp.features.sales.shipment.dto.ShipmentSaveRequest.class, "items"),
                new Target(com.uten.imp.features.stock.dto.StockDocSaveRequest.class, "items"),
                new Target(com.uten.imp.features.subcontract.application.dto.ApplicationSaveRequest.class, "items"),
                new Target(com.uten.imp.features.subcontract.inquiry.dto.InquirySaveRequest.class, "items"),
                new Target(com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueSaveRequest.class, "items"),
                new Target(com.uten.imp.features.subcontract.material_return.dto.MaterialReturnSaveRequest.class, "items"),
                new Target(com.uten.imp.features.subcontract.order.dto.OrderSaveRequest.class, "items"),
                new Target(com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest.class, "items"),
                new Target(com.uten.imp.features.subcontract.ret.dto.ReturnSaveRequest.class, "items"),
                new Target(com.uten.imp.features.subcontract.waste.dto.WasteSaveRequest.class, "items"),
                new Target(com.uten.imp.features.sales.shipment.dto.BatchShipRequest.class, "lines"),
                new Target(com.uten.imp.features.production.mrp.GenerateSubplansRequest.class, "items"),
                new Target(com.uten.imp.features.sales.order.dto.OrderChangeQtyRequest.class, "items"),
                new Target(com.uten.imp.features.production.schedule.dto.MergePlanRequest.class, "items"),
                new Target(com.uten.imp.features.stock.dto.StockDocIssueRequest.class, "lines"));

        for (Target target : targets) {
            Object request = target.type().getDeclaredConstructor().newInstance();
            Field field = target.type().getDeclaredField(target.field());
            field.setAccessible(true);
            field.set(
                    request,
                    Collections.nCopies(RequestLimits.DOCUMENT_LINES + 1, null));

            boolean rejected = validator.validate(request).stream()
                    .anyMatch(violation -> violation.getPropertyPath().toString().equals(target.field())
                            && violation.getConstraintDescriptor().getAnnotation() instanceof Size);
            assertTrue(rejected, target.type().getName() + "." + target.field());
        }
    }

    @Test
    void administrativeAndNoticeCollectionsHaveSpecificLimits() {
        assertHasSizeViolation(
                new AdminUserController.DataScopesBody(
                        Collections.nCopies(RequestLimits.ADMIN_SCOPE_OWNERS + 1, UUID.randomUUID())),
                "ownerEmployeeIds");
        assertHasSizeViolation(
                new DepartmentPermissionsDto(
                        Collections.nCopies(RequestLimits.PERMISSION_CODES + 1, "goods:view")),
                "permissions");
        assertHasSizeViolation(
                new PermissionOverridesDto(
                        Collections.nCopies(RequestLimits.PERMISSION_CODES + 1, "goods:view"),
                        List.of()),
                "grants");
        assertHasSizeViolation(
                new NoticeBatchDeleteRequest(
                        Collections.nCopies(RequestLimits.BATCH_IDS + 1, UUID.randomUUID())),
                "ids");
        assertHasSizeViolation(
                new NoticePublishRequest(
                        "title",
                        "content",
                        "announcement",
                        false,
                        "normal",
                        Collections.nCopies(RequestLimits.NOTICE_ATTACHMENTS + 1, "file.pdf"),
                        "all",
                        List.of(),
                        List.of()),
                "attachments");
        assertHasSizeViolation(
                new NoticePublishRequest(
                        "title",
                        "content",
                        "announcement",
                        false,
                        "normal",
                        List.of(),
                        "selected",
                        Collections.nCopies(
                                RequestLimits.NOTICE_AUDIENCE_TARGETS + 1,
                                UUID.randomUUID()),
                        List.of()),
                "departmentIds");
        assertHasSizeViolation(
                new NoticePublishRequest(
                        "title",
                        "content",
                        "announcement",
                        false,
                        "normal",
                        List.of(),
                        "selected",
                        List.of(),
                        Collections.nCopies(
                                RequestLimits.NOTICE_AUDIENCE_TARGETS + 1,
                                UUID.randomUUID())),
                "employeeIds");
        assertHasSizeViolation(
                new NoticePublishRequest(
                        "x".repeat(RequestLimits.NOTICE_TITLE_LENGTH + 1),
                        "content",
                        "announcement",
                        false,
                        "normal",
                        List.of(),
                        "all",
                        List.of(),
                        List.of()),
                "title");
        assertHasSizeViolation(
                new NoticeAudienceRequest(
                        Collections.nCopies(
                                RequestLimits.NOTICE_AUDIENCE_TARGETS + 1,
                                UUID.randomUUID()),
                        List.of()),
                "departmentIds");
    }

    @Test
    void profileAndEmployeeNestedCollectionsRejectOversizedPayloads() throws Exception {
        assertHasSizeViolation(
                new ProfileChangeDto.SubmitRequest(
                        null,
                        Collections.nCopies(
                                RequestLimits.PROFILE_CHANGES + 1,
                                new ProfileChangeDto.FieldChange("email", "邮箱", "a@b.example")),
                        "idempotency-key"),
                "changes");

        List<OnboardingRequest.EmergencyContactInput> contacts = Collections.nCopies(
                RequestLimits.EMPLOYEE_NESTED_ITEMS + 1,
                new OnboardingRequest.EmergencyContactInput("name", "13800000000", "family", 1));
        assertHasSizeViolation(
                new OnboardingRequest(null, null, null, null, contacts, null, null, null),
                "emergencyContacts");
        assertHasSizeViolation(
                new OnboardingRequest(
                        null,
                        null,
                        null,
                        null,
                        null,
                        Collections.nCopies(
                                RequestLimits.EMPLOYEE_NESTED_ITEMS + 1,
                                new OnboardingRequest.CredentialInput(
                                        "type", "name", "no", null, null)),
                        null,
                        null),
                "certificates");
        assertHasSizeViolation(
                new OnboardingRequest(
                        null,
                        null,
                        null,
                        null,
                        null,
                        null,
                        Collections.nCopies(
                                RequestLimits.EMPLOYEE_NESTED_ITEMS + 1,
                                new OnboardingRequest.EducationInput(
                                        "degree", "school", "major", null, null)),
                        null),
                "educations");
        assertHasSizeViolation(
                new OnboardingRequest(
                        null,
                        null,
                        null,
                        null,
                        null,
                        null,
                        null,
                        new OnboardingRequest.Account(
                                Collections.nCopies(
                                        RequestLimits.EMPLOYEE_NESTED_ITEMS + 1, "employee"),
                                "account")),
                "account.roles");

        assertHasSizeViolation(
                recordWithCollection(
                        UpdateEmployeeRequest.class,
                        "certificates",
                        Collections.nCopies(
                                RequestLimits.EMPLOYEE_NESTED_ITEMS + 1,
                                new OnboardingRequest.CredentialInput(
                                        "type", "name", "no", null, null))),
                "certificates");
        assertHasSizeViolation(
                recordWithCollection(
                        UpdateEmployeeRequest.class,
                        "educations",
                        Collections.nCopies(
                                RequestLimits.EMPLOYEE_NESTED_ITEMS + 1,
                                new OnboardingRequest.EducationInput(
                                        "degree", "school", "major", null, null))),
                "educations");
    }

    @Test
    void noticeControllerReturnsValidationContractBeforeCallingService() throws Exception {
        NoticeService service = mock(NoticeService.class);
        MockMvc mvc = MockMvcBuilders.standaloneSetup(new NoticeController(
                        service,
                        mock(com.uten.imp.features.notice.NoticeAudienceService.class),
                        mock(com.uten.imp.security.SecurityContextCurrentUser.class)))
                .setControllerAdvice(new GlobalExceptionHandler())
                .build();

        mvc.perform(post("/api/notices/batch-delete")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"ids\":" + uuidArrayJson(RequestLimits.BATCH_IDS + 1) + "}"))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value(ErrorCode.VALIDATION_FAILED.name()));
        verifyNoInteractions(service);
    }

    @Test
    void dataScopesControllerReturnsValidationContractBeforeCallingService() throws Exception {
        DataScopeAdminService dataScopeService = mock(DataScopeAdminService.class);
        AdminUserController controller = new AdminUserController(
                mock(UserAccountAdminService.class),
                mock(RoleAdminService.class),
                mock(PermissionOverrideAdminService.class),
                dataScopeService);
        MockMvc mvc = MockMvcBuilders.standaloneSetup(controller)
                .setControllerAdvice(new GlobalExceptionHandler())
                .build();

        mvc.perform(put("/api/admin/users/{id}/data-scopes", UUID.randomUUID())
                        .queryParam("scope", "goods")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"ownerEmployeeIds\":"
                                + uuidArrayJson(RequestLimits.ADMIN_SCOPE_OWNERS + 1)
                                + "}"))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value(ErrorCode.VALIDATION_FAILED.name()));
        verifyNoInteractions(dataScopeService);
    }

    @Test
    void profileChangeControllerValidatesOversizedChangesBeforeCallingService() throws Exception {
        ProfileChangeSubmitService submitService = mock(ProfileChangeSubmitService.class);
        ProfileChangeController controller = new ProfileChangeController(
                submitService,
                mock(ProfileChangeQueryService.class),
                mock(ProfileChangeReviewService.class));
        MockMvc mvc = MockMvcBuilders.standaloneSetup(controller)
                .setControllerAdvice(new GlobalExceptionHandler())
                .build();
        String changes = "["
                + String.join(
                        ",",
                        Collections.nCopies(
                                RequestLimits.PROFILE_CHANGES + 1,
                                "{\"fieldCode\":\"email\",\"newValue\":\"a@b.example\"}"))
                + "]";

        mvc.perform(post("/api/profile/me/changes")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"changes\":" + changes + ",\"idemKey\":\"idem\"}"))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value(ErrorCode.VALIDATION_FAILED.name()));
        verifyNoInteractions(submitService);
    }

    @Test
    void goodsLookupRejectsEmptyAndOversizedSetsBeforeCallingService() {
        GoodsService service = mock(GoodsService.class);
        GoodsController controller = new GoodsController(
                service,
                mock(XlsxExportService.class),
                mock(EncryptedWorkbookService.class),
                mock(AuditService.class),
                mock(SecurityContextCurrentUser.class));

        assertValidationFailure(() -> controller.lookup(null));
        assertValidationFailure(() -> controller.lookup(Set.of()));
        Set<UUID> oversized = new HashSet<>();
        while (oversized.size() <= RequestLimits.LOOKUP_IDS) {
            oversized.add(UUID.randomUUID());
        }
        assertValidationFailure(() -> controller.lookup(oversized));
        verifyNoInteractions(service);
    }

    @Test
    void suggestFinishFailsClosedForMalformedOrOversizedMapPayloads() {
        ProductionScheduleService service = mock(ProductionScheduleService.class);
        ProductionScheduleController controller = new ProductionScheduleController(service);

        assertValidationFailure(() -> controller.suggestFinish(body("not-an-array")));
        assertValidationFailure(() -> controller.suggestFinish(body(List.of())));
        assertValidationFailure(() -> controller.suggestFinish(body(
                Collections.nCopies(RequestLimits.DOCUMENT_LINES + 1, Map.of()))));
        assertValidationFailure(() -> controller.suggestFinish(body(List.of("not-an-object"))));
        assertValidationFailure(() -> controller.suggestFinish(
                body(List.of(Map.of("goodsId", "bad", "qty", 1)))));

        Map<String, Object> invalidDate =
                body(List.of(Map.of("goodsId", UUID.randomUUID().toString(), "qty", 1)));
        invalidDate.put("startDate", "2026-99-99");
        assertValidationFailure(() -> controller.suggestFinish(invalidDate));
        verifyNoInteractions(service);
    }

    private void assertHasSizeViolation(Object request, String property) {
        assertTrue(
                validator.validate(request).stream()
                        .anyMatch(violation -> violation.getPropertyPath().toString().equals(property)
                                && violation.getConstraintDescriptor().getAnnotation() instanceof Size),
                property);
    }

    private static void assertValidationFailure(org.junit.jupiter.api.function.Executable action) {
        ApiException exception = assertThrows(ApiException.class, action);
        assertEquals(ErrorCode.VALIDATION_FAILED, exception.getCode());
    }

    private static Map<String, Object> body(Object items) {
        Map<String, Object> body = new HashMap<>();
        body.put("items", items);
        return body;
    }

    private static String uuidArrayJson(int size) {
        return "["
                + String.join(
                        ",",
                        Collections.nCopies(size, "\"" + UUID.randomUUID() + "\""))
                + "]";
    }

    private static Object recordWithCollection(
            Class<?> recordType, String componentName, List<?> value) throws Exception {
        RecordComponent[] components = recordType.getRecordComponents();
        Class<?>[] types = new Class<?>[components.length];
        Object[] values = new Object[components.length];
        for (int i = 0; i < components.length; i++) {
            types[i] = components[i].getType();
            if (components[i].getName().equals(componentName)) {
                values[i] = value;
            }
        }
        return recordType.getDeclaredConstructor(types).newInstance(values);
    }

    private record Target(Class<?> type, String field) {}
}
