package com.uten.imp.features.org.employee;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.test.util.ReflectionTestUtils;

import java.time.LocalDate;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/** 修改证件信息 (V807)：严格校验、查重、证件类型一起改、身份证重推出生日期与性别。 */
@ExtendWith(MockitoExtension.class)
class EmployeeCommandServiceChangeIdentityTest {

    private static final String VALID_ID = "11010519491231002X";

    @Mock private EmployeeRepository empRepo;
    @Mock private EmployeeSensitiveRepository sensitiveRepo;
    @Mock private UserAccountRepository userRepo;
    @Mock private TxSessionVars tx;
    @Mock private EmployeeQueryService queryService;

    @InjectMocks
    private EmployeeCommandService service;

    private Employee employee;

    @BeforeEach
    void setUp() {
        // 真实的唯一写入口：校验、查重与校验结果都走生产代码。
        ReflectionTestUtils.setField(service, "piiWriter", new EmployeePiiWriter(tx, sensitiveRepo));
        employee = new Employee();
        employee.setCode("UT0011");
        employee.setFullName("证件测试员工");
        employee.setIdType("身份证");
        employee.setStatus("active");
        employee.setGender("male");
        employee.setBirthMonthDay("01-01");
        employee.setHireDate(LocalDate.of(2026, 1, 5));
        when(queryService.requireEmployee(employee.getId())).thenReturn(employee);
    }

    @Test
    void superAdminEmployeeIsForbidden() {
        UserAccount account = new UserAccount();
        account.setSuperAdmin(true);
        when(userRepo.findByEmployeeId(employee.getId())).thenReturn(Optional.of(account));

        ApiException error = assertThrows(ApiException.class,
                () -> service.changeIdentity(employee.getId(), "身份证", VALID_ID));

        assertEquals(ErrorCode.FORBIDDEN, error.getCode());
        assertEquals("禁止通过员工管理修改超级管理员的证件信息", error.getMessage());
        assertNothingWritten();
    }

    @Test
    void unknownDocumentTypeIsRejectedBeforeAnyWrite() {
        ApiException error = assertThrows(ApiException.class,
                () -> service.changeIdentity(employee.getId(), "驾驶证", "D123456"));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
        assertEquals("证件类型不正确", error.getMessage());
        assertNothingWritten();
    }

    @Test
    void invalidResidentIdentityNamesTheProblemAndWritesNothing() {
        EmployeeSensitive existing = sensitive("old-cipher", "check_digit");
        when(sensitiveRepo.findByEmployeeId(employee.getId())).thenReturn(Optional.of(existing));

        ApiException error = assertThrows(ApiException.class,
                () -> service.changeIdentity(employee.getId(), "身份证", "11010519491231002"));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
        assertEquals("身份证号应为18位，当前为17位", error.getMessage());
        assertEquals("old-cipher", existing.getIdCardEnc());
        assertEquals("check_digit", existing.getIdCardCheck());
        assertEquals("身份证", employee.getIdType());
        assertNothingWritten();
    }

    @Test
    void switchingToPassportFixesTheTypeAndClearsTheProblem() {
        EmployeeSensitive existing = sensitive("old-cipher", "check_digit");
        when(sensitiveRepo.findByEmployeeId(employee.getId())).thenReturn(Optional.of(existing));
        when(tx.hmac("E12345678")).thenReturn("passport-hmac");
        when(tx.encrypt("E12345678")).thenReturn("v2:passport");
        int versionBefore = employee.getVersion();

        service.changeIdentity(employee.getId(), " 护照 ", " E12345678 ");

        assertEquals("护照", employee.getIdType());
        assertEquals("v2:passport", existing.getIdCardEnc());
        assertEquals("5678", existing.getIdCardLast4());
        assertEquals("passport-hmac", existing.getIdCardHash());
        assertEquals("valid", existing.getIdCardCheck());
        // 非身份证不重推出生日期与性别
        assertEquals("male", employee.getGender());
        assertEquals("01-01", employee.getBirthMonthDay());
        assertNull(existing.getBirthDateEnc());
        assertEquals(versionBefore + 1, employee.getVersion().intValue());
        verify(sensitiveRepo).save(existing);
        verify(empRepo).save(employee);
    }

    @Test
    void residentIdentityRederivesBirthDateAndGender() {
        EmployeeSensitive existing = sensitive("old-cipher", "length:17");
        when(sensitiveRepo.findByEmployeeId(employee.getId())).thenReturn(Optional.of(existing));
        when(tx.hmac(VALID_ID)).thenReturn("id-hmac");
        when(tx.encrypt(VALID_ID)).thenReturn("v2:id");
        when(tx.encrypt("1949-12-31")).thenReturn("v2:birth");

        service.changeIdentity(employee.getId(), "身份证", " 11010519491231002x ");

        assertEquals("v2:id", existing.getIdCardEnc());
        assertEquals("002X", existing.getIdCardLast4());
        assertEquals("valid", existing.getIdCardCheck());
        assertEquals("v2:birth", existing.getBirthDateEnc());
        assertEquals("12-31", employee.getBirthMonthDay());
        assertEquals("female", employee.getGender());
        verify(tx).encrypt("1949-12-31");
    }

    @Test
    void missingSensitiveRowIsCreated() {
        when(sensitiveRepo.findByEmployeeId(employee.getId())).thenReturn(Optional.empty());
        when(tx.hmac("H1234567")).thenReturn("hk-hmac");
        when(tx.encrypt("H1234567")).thenReturn("v2:hk");

        service.changeIdentity(employee.getId(), "港澳台通行证", "H1234567");

        ArgumentCaptor<EmployeeSensitive> saved = ArgumentCaptor.forClass(EmployeeSensitive.class);
        verify(sensitiveRepo).save(saved.capture());
        assertEquals(employee.getId(), saved.getValue().getEmployeeId());
        assertEquals("v2:hk", saved.getValue().getIdCardEnc());
        assertEquals("valid", saved.getValue().getIdCardCheck());
        assertEquals("港澳台通行证", employee.getIdType());
    }

    @Test
    void duplicateIdentityIsAConflictAndWritesNothing() {
        EmployeeSensitive existing = sensitive("old-cipher", "unchecked");
        when(sensitiveRepo.findByEmployeeId(employee.getId())).thenReturn(Optional.of(existing));
        when(tx.hmac(VALID_ID)).thenReturn("taken-hmac");
        when(sensitiveRepo.existsByIdCardHashAndEmployeeIdNot("taken-hmac", employee.getId()))
                .thenReturn(true);

        ApiException error = assertThrows(ApiException.class,
                () -> service.changeIdentity(employee.getId(), "身份证", VALID_ID));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertEquals("该证件号码已被其他员工使用，请核对是否录错或与其他员工档案重复", error.getMessage());
        assertSame("old-cipher", existing.getIdCardEnc());
        assertEquals("unchecked", existing.getIdCardCheck());
        assertNothingWritten();
    }

    private EmployeeSensitive sensitive(String cipher, String check) {
        EmployeeSensitive sensitive = new EmployeeSensitive();
        sensitive.setEmployeeId(employee.getId());
        sensitive.setIdCardEnc(cipher);
        sensitive.setIdCardCheck(check);
        return sensitive;
    }

    private void assertNothingWritten() {
        verify(sensitiveRepo, never()).save(any(EmployeeSensitive.class));
        verify(empRepo, never()).save(any(Employee.class));
        verify(tx, never()).encrypt(anyString());
    }
}
