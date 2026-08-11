package com.uten.imp.features.org.employee;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class EmployeePiiWriterTest {

    @Mock
    private TxSessionVars tx;
    @Mock
    private EmployeeSensitiveRepository repository;

    private EmployeePiiWriter writer;

    @BeforeEach
    void setUp() {
        writer = new EmployeePiiWriter(tx, repository);
    }

    @Test
    void phoneUpdateAlwaysRefreshesCiphertextAndLookupHashTogether() {
        EmployeeSensitive target = new EmployeeSensitive();
        when(tx.encrypt("13800138000")).thenReturn("v2:phone-cipher");
        when(tx.hmac("13800138000")).thenReturn("phone-hmac");

        writer.applyPhone(target, " 13800138000 ");

        assertEquals("v2:phone-cipher", target.getPhoneEnc());
        assertEquals("phone-hmac", target.getPhoneHash());
        verify(tx).encrypt("13800138000");
        verify(tx).hmac("13800138000");
    }

    @Test
    void identityUpdateRefreshesCiphertextHashAndDisplayMaskTogether() {
        UUID employeeId = UUID.randomUUID();
        EmployeeSensitive target = new EmployeeSensitive();
        when(tx.hmac("11010519491231002X")).thenReturn("id-hmac");
        when(repository.existsByIdCardHashAndEmployeeIdNot("id-hmac", employeeId))
                .thenReturn(false);
        when(tx.encrypt("11010519491231002X")).thenReturn("v2:id-cipher");

        writer.applyIdentity(
                target,
                employeeId,
                "身份证",
                " 11010519491231002x ");

        assertEquals("v2:id-cipher", target.getIdCardEnc());
        assertEquals("id-hmac", target.getIdCardHash());
        assertEquals("002X", target.getIdCardLast4());
    }

    @Test
    void duplicateIdentityIsRejectedBeforeEncryption() {
        UUID employeeId = UUID.randomUUID();
        EmployeeSensitive target = new EmployeeSensitive();
        when(tx.hmac("11010519491231002X")).thenReturn("duplicate");
        when(repository.existsByIdCardHashAndEmployeeIdNot("duplicate", employeeId))
                .thenReturn(true);

        assertThrows(ApiException.class,
                () -> writer.applyIdentity(
                        target,
                        employeeId,
                        "身份证",
                        "11010519491231002X"));
        verify(tx, never()).encrypt("11010519491231002X");
    }

    @Test
    void invalidResidentIdentityIsRejectedBeforeHashingOrEncryption() {
        UUID employeeId = UUID.randomUUID();
        EmployeeSensitive target = new EmployeeSensitive();

        assertThrows(
                ApiException.class,
                () -> writer.applyIdentity(
                        target,
                        employeeId,
                        "身份证",
                        "110105199902300021"));

        verify(tx, never()).hmac("110105199902300021");
        verify(tx, never()).encrypt("110105199902300021");
    }

    @Test
    void nonResidentDocumentIsTrimmedWithoutApplyingResidentIdRules() {
        UUID employeeId = UUID.randomUUID();
        EmployeeSensitive target = new EmployeeSensitive();
        when(tx.hmac("P1234567")).thenReturn("passport-hmac");
        when(repository.existsByIdCardHashAndEmployeeIdNot("passport-hmac", employeeId))
                .thenReturn(false);
        when(tx.encrypt("P1234567")).thenReturn("passport-cipher");

        writer.applyIdentity(target, employeeId, "护照", " P1234567 ");

        assertEquals("passport-cipher", target.getIdCardEnc());
        assertEquals("passport-hmac", target.getIdCardHash());
        assertEquals("4567", target.getIdCardLast4());
    }
}
