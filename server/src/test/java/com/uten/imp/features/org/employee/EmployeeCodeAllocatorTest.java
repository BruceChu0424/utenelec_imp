package com.uten.imp.features.org.employee;

import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class EmployeeCodeAllocatorTest {
    @Mock MasterCodeService masterCodes;
    @Mock EmployeeRepository employees;
    EmployeeCodeAllocator allocator;
    final UUID newEmployeeId=UUID.randomUUID();

    @BeforeEach void create(){allocator=new EmployeeCodeAllocator(masterCodes,employees);}
    @Test void newEmployeesUseSixDigitsAndNeverClaimRetiredUtNumbers() {
        when(masterCodes.nextCode(MasterCodePrefix.EMPLOYEE)).thenReturn("000203");
        assertThat(allocator.nextForNewEmployee(newEmployeeId)).isEqualTo("000203");
        assertThat(MasterCodePrefix.EMPLOYEE.code()).isEmpty();
        assertThat(MasterCodePrefix.EMPLOYEE.width()).isEqualTo(6);
        verify(masterCodes).nextCode(MasterCodePrefix.EMPLOYEE);
        verifyNoMoreInteractions(masterCodes);
    }
    @Test void fallbackKeepsTheExistingDefenseAgainstLegacyUnregisteredCodeCollisions() {
        when(masterCodes.nextCode(MasterCodePrefix.EMPLOYEE)).thenReturn("000203","000204");
        when(employees.existsByCode("000203")).thenReturn(true);
        assertThat(allocator.nextForNewEmployee(newEmployeeId)).isEqualTo("000204");
        verify(masterCodes,times(2)).nextCode(MasterCodePrefix.EMPLOYEE);
    }
    @ParameterizedTest @ValueSource(strings={"UT0171","000000","000001","000002","1000000","12345"})
    void rejectsLegacyMalformedAndReservedFounderNumbers(String code) {
        when(masterCodes.nextCode(MasterCodePrefix.EMPLOYEE)).thenReturn(code);
        assertThatThrownBy(()->allocator.nextForNewEmployee(newEmployeeId)).isInstanceOf(ApiException.class);
        verifyNoInteractions(employees);
    }
    @Test void aMissingNewUuidCannotClaimOrAdvanceAnything() {
        assertThatThrownBy(()->allocator.nextForNewEmployee(null)).isInstanceOf(ApiException.class);
        verifyNoInteractions(masterCodes,employees);
    }
}
