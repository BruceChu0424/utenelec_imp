package com.uten.imp.features.visitor;

import com.uten.imp.features.notice.HrNoticeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorApplyRequest;
import com.uten.imp.features.visitor.dto.VisitorAuthDto.SendCodeRequest;
import com.uten.imp.features.visitor.dto.VisitorAuthDto.VisitorLoginRequest;
import com.uten.imp.features.visitor.dto.VisitorAuthDto.VisitorRefreshRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.validation.Validation;
import jakarta.validation.Validator;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class VisitorRequestValidationTest {

    private final Validator validator = Validation
            .buildDefaultValidatorFactory()
            .getValidator();

    private VisitorApplicationRepository appRepo;
    private VisitorApprovalStepRepository stepRepo;
    private VisitorAccountRepository accountRepo;
    private EmployeeRepository employeeRepo;
    private VisitorApplicationMapper mapper;
    private TxSessionVars tx;
    private SecurityContextCurrentUser currentUser;
    private VisitorHostEligibility hostEligibility;
    private VisitorApplicationService service;
    private UUID visitorId;
    private VisitorAccount account;

    @BeforeEach
    void setUp() {
        appRepo = mock(VisitorApplicationRepository.class);
        stepRepo = mock(VisitorApprovalStepRepository.class);
        accountRepo = mock(VisitorAccountRepository.class);
        employeeRepo = mock(EmployeeRepository.class);
        mapper = mock(VisitorApplicationMapper.class);
        tx = mock(TxSessionVars.class);
        currentUser = mock(SecurityContextCurrentUser.class);
        hostEligibility = mock(VisitorHostEligibility.class);
        service = new VisitorApplicationService(
                appRepo,
                stepRepo,
                accountRepo,
                employeeRepo,
                mapper,
                tx,
                mock(HrNoticeService.class),
                currentUser,
                hostEligibility);

        visitorId = UUID.randomUUID();
        account = new VisitorAccount();
        account.setPhoneEnc("verified-phone-ciphertext");
        when(currentUser.id()).thenReturn(Optional.of(visitorId));
        when(accountRepo.findAndLockById(visitorId)).thenReturn(Optional.of(account));
    }

    @Test
    void authRequestsRejectMalformedOrOversizedInputs() {
        assertFalse(validator.validate(new SendCodeRequest("138abc00138000")).isEmpty());
        assertFalse(validator.validate(
                new VisitorLoginRequest("13800138000", "12345x")).isEmpty());
        assertFalse(validator.validate(
                new VisitorRefreshRequest("x".repeat(513))).isEmpty());

        assertEquals(
                0,
                validator.validate(
                        new VisitorLoginRequest("+8613800138000", "123456")).size());
    }

    @Test
    void applyRequestRequiresBoundedCoreFieldsAndHost() {
        VisitorApplyRequest invalid = new VisitorApplyRequest(
                "x".repeat(101),
                null,
                null,
                null,
                " ",
                false,
                null,
                null,
                null,
                OffsetDateTime.now(),
                null);

        var fields = validator.validate(invalid).stream()
                .map(violation -> violation.getPropertyPath().toString())
                .toList();

        assertEquals(List.of("hostEmployeeId", "visitPurpose", "visitorName"),
                fields.stream().sorted().toList());
    }

    @Test
    void submitRejectsInvalidTimeRangeAndMissingVehiclePlate() {
        OffsetDateTime visitAt = OffsetDateTime.now().plusHours(1);
        ApiException invalidRange = assertThrows(
                ApiException.class,
                () -> service.submit(request(
                        UUID.randomUUID(), null, false, null, visitAt, visitAt)));
        assertEquals(ErrorCode.VALIDATION_FAILED, invalidRange.getCode());

        ApiException missingPlate = assertThrows(
                ApiException.class,
                () -> service.submit(request(
                        UUID.randomUUID(), null, true, " ", visitAt, null)));
        assertEquals(ErrorCode.VALIDATION_FAILED, missingPlate.getCode());

        ApiException pastVisitAt = assertThrows(
                ApiException.class,
                () -> service.submit(request(
                        UUID.randomUUID(), null, false, null,
                        OffsetDateTime.now().minusMinutes(1), null)));
        assertEquals(ErrorCode.VALIDATION_FAILED, pastVisitAt.getCode());
    }

    @Test
    void submitRejectsUnknownOrMismatchedHost() {
        UUID hostId = UUID.randomUUID();
        OffsetDateTime visitAt = OffsetDateTime.now().plusHours(1);
        when(employeeRepo.findById(hostId)).thenReturn(Optional.empty());

        ApiException unknown = assertThrows(
                ApiException.class,
                () -> service.submit(request(
                        hostId, null, false, null, visitAt, null)));
        assertEquals(ErrorCode.VALIDATION_FAILED, unknown.getCode());

        Employee host = eligibleHost(hostId);
        when(employeeRepo.findById(hostId)).thenReturn(Optional.of(host));
        when(hostEligibility.isEligible(hostId)).thenReturn(true);
        ApiException mismatch = assertThrows(
                ApiException.class,
                () -> service.submit(request(
                        hostId, UUID.randomUUID(), false, null, visitAt, null)));
        assertEquals(ErrorCode.VALIDATION_FAILED, mismatch.getCode());
        assertEquals("接待人与接待部门不匹配，请重新选择", mismatch.getMessage());
    }

    /** security-08：在职但不在可对外接待白名单里的员工，拿猜到的编号也挂不上申请。 */
    @Test
    void submitRejectsACurrentEmployeeOutsideTheHostWhitelist() {
        UUID hostId = UUID.randomUUID();
        when(employeeRepo.findById(hostId)).thenReturn(Optional.of(eligibleHost(hostId)));
        when(hostEligibility.isEligible(hostId)).thenReturn(false);

        ApiException rejected = assertThrows(
                ApiException.class,
                () -> service.submit(request(
                        hostId, null, false, null, OffsetDateTime.now().plusHours(1), null)));

        assertEquals(ErrorCode.VALIDATION_FAILED, rejected.getCode());
        assertEquals("接待人不存在或当前不可接待", rejected.getMessage());
        verify(appRepo, org.mockito.Mockito.never()).save(any());
    }

    @Test
    void submitRejectsInvalidEighteenDigitResidentIdentity() {
        UUID hostId = UUID.randomUUID();
        when(employeeRepo.findById(hostId))
                .thenReturn(Optional.of(eligibleHost(hostId)));
        when(hostEligibility.isEligible(hostId)).thenReturn(true);
        OffsetDateTime visitAt = OffsetDateTime.now().plusHours(1);

        VisitorApplyRequest request = new VisitorApplyRequest(
                "访客",
                null,
                "110105199902300021",
                null,
                "商务洽谈",
                false,
                null,
                hostId,
                null,
                visitAt,
                null);

        ApiException exception =
                assertThrows(ApiException.class, () -> service.submit(request));

        assertEquals(ErrorCode.VALIDATION_FAILED, exception.getCode());
        assertEquals("身份证号第7-14位不是有效的出生日期", exception.getMessage());
        verify(appRepo, org.mockito.Mockito.never()).save(any());
    }

    /**
     * 任何非空身份证号都按 18 位居民身份证校验并说出具体哪里不对 (与员工档案、前端 problemOf 同一句话)；
     * 15 位老证号同样拒绝，不再被 DTO 格式校验笼统地挡成「格式不正确」。
     */
    @Test
    void submitNamesTheSpecificIdentityProblemForAnyNonEmptyNumber() {
        UUID hostId = UUID.randomUUID();
        when(employeeRepo.findById(hostId)).thenReturn(Optional.of(eligibleHost(hostId)));
        when(hostEligibility.isEligible(hostId)).thenReturn(true);

        assertEquals("身份证号应为18位，当前为17位",
                identityRejection(hostId, "11010519491231002"));
        assertEquals("身份证号应为18位，当前为15位",
                identityRejection(hostId, "110105491231002"));
        assertEquals("身份证号应为18位，当前为19位",
                identityRejection(hostId, "11010519491231002X1"));
        assertEquals("身份证号第5位不是数字(只有第18位可以是X)",
                identityRejection(hostId, "1101A519491231002X"));
        assertEquals("身份证号第18位校验码与前17位不符，通常是某一位数字录错或相邻两位颠倒，请对照证件逐位核对",
                identityRejection(hostId, "110105194912310021"));
        verify(appRepo, org.mockito.Mockito.never()).save(any());
    }

    @Test
    void identityFormatIsLeftToTheServiceSoTheRequestOnlyCapsAbsurdLength() {
        for (String number : List.of("11010519491231002", "110105491231002", "1101A519491231002X")) {
            assertEquals(List.of(), validator.validate(withIdentity(UUID.randomUUID(), number)).stream()
                    .map(violation -> violation.getPropertyPath().toString())
                    .toList(), "format problems get the specific message from the service");
        }
        var tooLong = validator.validate(withIdentity(UUID.randomUUID(), "1".repeat(33)));
        assertEquals(1, tooLong.size());
        assertEquals("身份证号过长，应为18位", tooLong.iterator().next().getMessage());
    }

    @Test
    void blankIdentityIsOptionalAndAValidOneIsNormalizedBeforeEncryption() {
        UUID hostId = UUID.randomUUID();
        when(employeeRepo.findById(hostId)).thenReturn(Optional.of(eligibleHost(hostId)));
        when(hostEligibility.isEligible(hostId)).thenReturn(true);
        when(tx.encrypt(any())).thenAnswer(invocation -> "encrypted:" + invocation.getArgument(0));
        when(appRepo.save(any())).thenAnswer(invocation -> invocation.getArgument(0));
        when(stepRepo.findByApplicationIdOrderByActedAtAsc(any())).thenReturn(List.of());
        when(mapper.hostInfo(any())).thenReturn(new String[]{"接待人", "部门"});

        service.submit(withIdentity(hostId, "   "));
        service.submit(withIdentity(hostId, " 11010519491231002x "));

        ArgumentCaptor<VisitorApplication> captor = ArgumentCaptor.forClass(VisitorApplication.class);
        verify(appRepo, org.mockito.Mockito.times(2)).save(captor.capture());
        assertEquals(null, captor.getAllValues().get(0).getIdCardEnc());
        assertEquals("encrypted:11010519491231002X", captor.getAllValues().get(1).getIdCardEnc());
        assertEquals("002X", captor.getAllValues().get(1).getIdCardLast4());
    }

    private String identityRejection(UUID hostId, String idCardNo) {
        ApiException error = assertThrows(ApiException.class,
                () -> service.submit(withIdentity(hostId, idCardNo)));
        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
        return error.getMessage();
    }

    private static VisitorApplyRequest withIdentity(UUID hostId, String idCardNo) {
        return new VisitorApplyRequest(
                "访客",
                null,
                idCardNo,
                null,
                "商务洽谈",
                false,
                null,
                hostId,
                null,
                OffsetDateTime.now().plusHours(1),
                null);
    }

    @Test
    void submitDerivesDepartmentAndKeepsSmsVerifiedPhoneIdentity() {
        UUID hostId = UUID.randomUUID();
        Employee host = eligibleHost(hostId);
        UUID departmentId = host.getDepartment().getId();
        when(employeeRepo.findById(hostId)).thenReturn(Optional.of(host));
        when(hostEligibility.isEligible(hostId)).thenReturn(true);
        when(tx.encrypt(any())).thenAnswer(invocation ->
                "encrypted:" + invocation.getArgument(0));
        when(appRepo.save(any())).thenAnswer(invocation -> invocation.getArgument(0));
        when(stepRepo.findByApplicationIdOrderByActedAtAsc(any())).thenReturn(List.of());
        when(mapper.hostInfo(any())).thenReturn(new String[]{"接待人", "部门"});

        service.submit(new VisitorApplyRequest(
                " 访客 ",
                "13900139000",
                "11010519491231002X",
                " 单位 ",
                " 商务洽谈 ",
                true,
                " 粤A12345 ",
                hostId,
                departmentId,
                OffsetDateTime.now().plusHours(1),
                OffsetDateTime.now().plusHours(2)));

        ArgumentCaptor<VisitorApplication> captor =
                ArgumentCaptor.forClass(VisitorApplication.class);
        verify(appRepo).save(captor.capture());
        VisitorApplication saved = captor.getValue();
        assertEquals("verified-phone-ciphertext", saved.getPhoneEnc());
        assertEquals(departmentId, saved.getHostDepartmentId());
        assertEquals("访客", saved.getVisitorName());
        assertEquals("单位", saved.getCompany());
        assertEquals("商务洽谈", saved.getVisitPurpose());
        assertEquals("encrypted:粤A12345", saved.getPlateNoEnc());
    }

    private static VisitorApplyRequest request(
            UUID hostId,
            UUID departmentId,
            boolean hasVehicle,
            String plateNo,
            OffsetDateTime visitAt,
            OffsetDateTime leaveAt) {
        return new VisitorApplyRequest(
                "访客",
                null,
                null,
                null,
                "商务洽谈",
                hasVehicle,
                plateNo,
                hostId,
                departmentId,
                visitAt,
                leaveAt);
    }

    private static Employee eligibleHost(UUID id) {
        Department department = new Department();
        Employee employee = new Employee();
        employee.setId(id);
        employee.setStatus("active");
        employee.setDepartment(department);
        return employee;
    }
}
