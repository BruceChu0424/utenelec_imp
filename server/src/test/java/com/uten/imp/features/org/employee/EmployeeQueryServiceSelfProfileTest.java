package com.uten.imp.features.org.employee;

import com.uten.imp.application.port.AttachmentAccessPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.employee.dto.EmployeeDetail;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.DataAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.Spy;
import org.mockito.junit.jupiter.MockitoExtension;

import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class EmployeeQueryServiceSelfProfileTest {

    private static final UUID USER_ID = UUID.fromString("10000000-0000-0000-0000-000000000001");
    private static final UUID SELF_ID = UUID.fromString("20000000-0000-0000-0000-000000000001");
    private static final UUID OTHER_ID = UUID.fromString("20000000-0000-0000-0000-000000000002");

    private static final String ID_NUMBER = "440101199001011234";
    private static final String PRIMARY_PHONE = "13812345678";
    private static final String EMERGENCY_PHONE = "13912345678";
    private static final String ALTERNATE_PHONE = "13612345678";
    private static final String BANK_ACCOUNT = "6222020000001234567";
    private static final String BANK_BRANCH = "优腾支行";

    @Mock private EmployeeRepository empRepo;
    @Mock private EmployeeListQuery employeeListQuery;
    @Mock private EmployeeSensitiveRepository sensitiveRepo;
    @Mock private EmployeeCompensationRepository compensationRepo;
    @Mock private EmergencyContactRepository emergencyRepo;
    @Mock private EmployeeCredentialRepository credentialRepo;
    @Mock private EmployeeEducationRepository educationRepo;
    @Mock private EmployeeContractRepository contractRepo;
    @Mock private EmploymentHistoryRepository historyRepo;
    @Mock private DepartmentRepository deptRepo;
    @Mock private UserAccountRepository userRepo;
    @Mock private TxSessionVars tx;
    @Spy private DataAccessPolicy policy = new DataAccessPolicy();
    @Mock private SecurityContextCurrentUser currentUser;
    @Mock private EmployeeVehiclePhoneService vehiclePhoneService;
    @Mock private AttachmentAccessPort attachmentAccess;

    @InjectMocks
    private EmployeeQueryService service;

    @Test
    void selfWithBasePermissionSeesOwnPersonalPiiButNotBankOrCompensation() {
        when(currentUser.get()).thenReturn(Optional.of(staff(SELF_ID, Set.of("profile:edit:self"))));
        stubDetail(SELF_ID, "本人");

        EmployeeDetail detail = service.myDetail();

        assertEquals(SELF_ID, detail.getId());
        assertEquals(ID_NUMBER, detail.getIdNumber());
        assertEquals(PRIMARY_PHONE, detail.getPhone());
        assertEquals("汉族", detail.getEthnicity());
        assertEquals(LocalDate.of(1990, 1, 1), detail.getBirthDate());
        assertEquals("群众", detail.getPoliticalStatus());
        assertEquals("已婚", detail.getMaritalStatus());
        assertEquals("广东省中山市户籍地址", detail.getHujiAddress());
        assertEquals("广东省中山市现住址", detail.getResidenceAddress());
        assertEquals(EMERGENCY_PHONE, detail.getEmergencyContacts().get(0).getPhone());
        assertEquals(ALTERNATE_PHONE, detail.getPhones().get(0).getPhone());

        assertNull(detail.getBankAccount());
        assertNull(detail.getBankBranch());
        assertNull(detail.getBaseSalary());
        assertNull(detail.getPerfSalary());
        assertNull(detail.getSocialInsuranceBase());
        assertNull(detail.getSocialInsuranceLocation());
        assertNull(detail.getHousingFundBase());
        assertNull(detail.getAllowanceStandard());
        verify(tx, never()).decrypt(BANK_ACCOUNT);
        verify(tx, never()).decrypt(BANK_BRANCH);
    }

    @Test
    void ordinaryOtherEmployeeDetailKeepsExistingMaskingAndOmission() {
        when(currentUser.get()).thenReturn(Optional.of(staff(
                SELF_ID,
                Set.of("profile:edit:self", "employee:view"))));
        stubDetail(OTHER_ID, "其他员工");

        EmployeeDetail detail = service.detail(OTHER_ID);

        assertEquals("****1234", detail.getIdNumber());
        assertEquals("138****5678", detail.getPhone());
        assertNull(detail.getEthnicity());
        assertNull(detail.getBirthDate());
        assertNull(detail.getPoliticalStatus());
        assertNull(detail.getMaritalStatus());
        assertNull(detail.getHujiAddress());
        assertNull(detail.getResidenceAddress());
        assertEquals("139****5678", detail.getEmergencyContacts().get(0).getPhone());
        assertEquals("136****5678", detail.getPhones().get(0).getPhone());
        assertNull(detail.getBankAccount());
        assertNull(detail.getBaseSalary());
    }

    @Test
    void unboundStaffFailsClosedBeforeAnyEmployeeLookup() {
        when(currentUser.get()).thenReturn(Optional.of(staff(null, Set.of("profile:edit:self"))));

        ApiException error = assertThrows(ApiException.class, service::myDetail);

        assertEquals(ErrorCode.NOT_FOUND, error.getCode());
        verifyNoInteractions(empRepo);
    }

    @Test
    void visitorFailsClosedEvenIfGrantedSelfProfilePermission() {
        AuthUser visitor = AuthUser.visitor(
                UUID.fromString("30000000-0000-0000-0000-000000000001"),
                "visitor-account",
                "V0001",
                Set.of("profile:edit:self"));
        when(currentUser.get()).thenReturn(Optional.of(visitor));

        ApiException error = assertThrows(ApiException.class, service::myDetail);

        assertEquals(ErrorCode.FORBIDDEN, error.getCode());
        verifyNoInteractions(empRepo);
    }

    private void stubDetail(UUID employeeId, String fullName) {
        Employee employee = new Employee();
        employee.setId(employeeId);
        employee.setCode("E-" + employeeId.toString().substring(0, 4));
        employee.setFullName(fullName);
        employee.setGender("female");
        employee.setIdType("居民身份证");
        employee.setEthnicity("汉族");
        employee.setHireDate(LocalDate.of(2020, 1, 1));
        employee.setStatus("active");
        employee.setEmploymentType("full_time");

        EmployeeSensitive sensitive = new EmployeeSensitive();
        sensitive.setEmployeeId(employeeId);
        sensitive.setIdCardEnc(ID_NUMBER);
        sensitive.setPhoneEnc(PRIMARY_PHONE);
        sensitive.setBankAccountEnc(BANK_ACCOUNT);
        sensitive.setBankBranchEnc(BANK_BRANCH);
        sensitive.setBirthDateEnc("1990-01-01");
        sensitive.setPoliticalStatusEnc("群众");
        sensitive.setMaritalStatusEnc("已婚");
        sensitive.setHujiAddressEnc("广东省中山市户籍地址");
        sensitive.setResidenceAddressEnc("广东省中山市现住址");
        sensitive.setOfficePhoneEnc("0760-12345678");
        sensitive.setEmailEnc("employee@example.test");

        EmployeeCompensation compensation = new EmployeeCompensation();
        compensation.setEmployeeId(employeeId);
        compensation.setBaseSalaryEnc("10000");
        compensation.setPerfSalaryEnc("2000");
        compensation.setSocialInsuranceBaseEnc("8000");
        compensation.setSocialInsuranceLocation("中山");
        compensation.setHousingFundBaseEnc("8000");
        compensation.setAllowanceStandardEnc("500");

        EmergencyContact emergency = new EmergencyContact();
        emergency.setEmployee(employee);
        emergency.setName("紧急联系人");
        emergency.setPhoneEnc(EMERGENCY_PHONE);
        emergency.setRelationship("家属");

        when(empRepo.findById(employeeId)).thenReturn(Optional.of(employee));
        when(sensitiveRepo.findByEmployeeId(employeeId)).thenReturn(Optional.of(sensitive));
        when(compensationRepo.findByEmployeeId(employeeId)).thenReturn(Optional.of(compensation));
        when(contractRepo.findByEmployeeIdOrderBySignOrderAsc(employeeId)).thenReturn(List.of());
        when(contractRepo.countByEmployeeId(employeeId)).thenReturn(0L);
        when(attachmentAccess.listVisible("EMPLOYEE", employeeId))
                .thenReturn(List.of());
        when(userRepo.findByEmployeeId(employeeId)).thenReturn(Optional.empty());
        when(emergencyRepo.findByEmployeeIdOrderBySortOrderAsc(employeeId))
                .thenReturn(List.of(emergency));
        when(historyRepo.findByEmployeeIdOrderByEventDateDesc(employeeId)).thenReturn(List.of());
        when(credentialRepo.findByEmployeeId(employeeId)).thenReturn(List.of());
        when(educationRepo.findByEmployeeIdOrderByEndDateDesc(employeeId)).thenReturn(List.of());
        when(vehiclePhoneService.listVehicles(employeeId)).thenReturn(List.of());
        when(vehiclePhoneService.listPhones(employeeId)).thenReturn(List.of(
                new EmployeeVehiclePhoneService.PhoneRow(
                        UUID.fromString("40000000-0000-0000-0000-000000000001"),
                        "备用",
                        ALTERNATE_PHONE)));
        when(tx.decrypt(anyString())).thenAnswer(invocation -> invocation.getArgument(0));
    }

    private static AuthUser staff(UUID employeeId, Set<String> permissions) {
        return new AuthUser(
                USER_ID,
                employeeId,
                "employee",
                Set.of(),
                permissions,
                false,
                true,
                false);
    }
}
