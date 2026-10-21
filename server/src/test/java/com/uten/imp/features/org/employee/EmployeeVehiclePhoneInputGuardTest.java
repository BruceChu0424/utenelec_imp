package com.uten.imp.features.org.employee;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.org.employee.dto.NestedDtos;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;

import java.util.Collections;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;

class EmployeeVehiclePhoneInputGuardTest {
    @Test
    void nullEntriesAreRejectedBeforeDeletingEitherExistingCollection() {
        var vehicles = mock(EmployeeVehicleRepository.class);
        var phones = mock(EmployeePhoneRepository.class);
        var employees = mock(EmployeeRepository.class);
        var tx = mock(TxSessionVars.class);
        var service = new EmployeeVehiclePhoneService(vehicles, phones, employees, tx);
        var employee = mock(Employee.class);

        assertThatThrownBy(() -> service.replaceVehicles(employee,
                Collections.<NestedDtos.VehicleInput>singletonList(null)))
                .isInstanceOfSatisfying(ApiException.class,
                        failure -> assertThat(failure.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
        assertThatThrownBy(() -> service.replacePhones(employee,
                Collections.<NestedDtos.PhoneInput>singletonList(null)))
                .isInstanceOfSatisfying(ApiException.class,
                        failure -> assertThat(failure.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
        verifyNoInteractions(vehicles, phones, employees, tx, employee);
    }
}
