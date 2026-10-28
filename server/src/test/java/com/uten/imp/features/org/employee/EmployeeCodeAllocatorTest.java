package com.uten.imp.features.org.employee;

import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class EmployeeCodeAllocatorTest {
    @Mock EntityManager em;
    @Mock Query query;
    @Mock MasterCodeService masterCodes;
    @Mock EmployeeRepository employees;
    EmployeeCodeAllocator allocator;
    final UUID newEmployeeId=UUID.randomUUID();

    @BeforeEach void create(){allocator=new EmployeeCodeAllocator(em,masterCodes,employees);}
    private void released(Object value) {
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter("employeeId",newEmployeeId)).thenReturn(query);
        when(query.getSingleResult()).thenReturn(value);
    }
    @Test void releasedEmployeeNumberIsClaimedForTheNewUuidBeforeAdvancingAnySequence() {
        released("UT0171");
        assertThat(allocator.nextForNewEmployee(newEmployeeId)).isEqualTo("UT0171");
        verify(query).setParameter("employeeId",newEmployeeId);
        verifyNoInteractions(masterCodes);
    }
    @Test void anEmptyReleasePoolUsesOnlyTheExistingEmployeeSequence() {
        released(null);when(masterCodes.nextCode(MasterCodePrefix.EMPLOYEE)).thenReturn("UT0201");
        assertThat(allocator.nextForNewEmployee(newEmployeeId)).isEqualTo("UT0201");
        verify(masterCodes).nextCode(MasterCodePrefix.EMPLOYEE);
        verifyNoMoreInteractions(masterCodes);
    }
    @Test void fallbackKeepsTheExistingDefenseAgainstLegacyUnregisteredCodeCollisions() {
        released(null);when(masterCodes.nextCode(MasterCodePrefix.EMPLOYEE)).thenReturn("UT0201","UT0202");
        when(employees.existsByCode("UT0201")).thenReturn(true);
        assertThat(allocator.nextForNewEmployee(newEmployeeId)).isEqualTo("UT0202");
        verify(masterCodes,times(2)).nextCode(MasterCodePrefix.EMPLOYEE);
    }
    @ParameterizedTest @ValueSource(strings={"HP000001","UT0000","UT10000"})
    void anInvalidClaimCannotBeSilentlyConvertedToAnotherNamespaceOrAnotherNumber(String code) {
        released(code);
        assertThatThrownBy(()->allocator.nextForNewEmployee(newEmployeeId)).isInstanceOfSatisfying(ApiException.class,
                failure->assertThat(failure.getCode()).isEqualTo(ErrorCode.CONFLICT));
        verifyNoInteractions(masterCodes);
    }
    @Test void anUnexpectedLiveOwnerOfAClaimedCodeRollsBackInsteadOfSpendingAnotherNumber() {
        released("UT0171");when(employees.existsByCode("UT0171")).thenReturn(true);
        assertThatThrownBy(()->allocator.nextForNewEmployee(newEmployeeId)).isInstanceOf(ApiException.class);
        verifyNoInteractions(masterCodes);
    }
    @Test void aMissingNewUuidCannotClaimOrAdvanceAnything() {
        assertThatThrownBy(()->allocator.nextForNewEmployee(null)).isInstanceOf(ApiException.class);
        verifyNoInteractions(em,masterCodes,employees);
    }
}
