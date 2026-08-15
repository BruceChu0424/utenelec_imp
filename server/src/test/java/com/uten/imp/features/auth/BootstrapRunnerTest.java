package com.uten.imp.features.auth;

import com.uten.imp.config.props.BootstrapProperties;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.rbac.RoleRepository;
import com.uten.imp.features.rbac.UserRoleRepository;
import org.junit.jupiter.api.Test;
import org.springframework.boot.ApplicationArguments;
import org.springframework.security.crypto.password.PasswordEncoder;

import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class BootstrapRunnerTest {

    private final UserAccountRepository userRepository = mock(UserAccountRepository.class);
    private final EmployeeRepository employeeRepository = mock(EmployeeRepository.class);
    private final RoleRepository roleRepository = mock(RoleRepository.class);
    private final UserRoleRepository userRoleRepository = mock(UserRoleRepository.class);
    private final PasswordEncoder passwordEncoder = mock(PasswordEncoder.class);
    private final BootstrapProperties properties = new BootstrapProperties();
    private final BootstrapRunner runner = new BootstrapRunner(
            userRepository,
            employeeRepository,
            roleRepository,
            userRoleRepository,
            passwordEncoder,
            properties);

    BootstrapRunnerTest() {
        properties.setAdminLogin("bootstrap-admin-test");
    }

    @Test
    void missingBootstrapLoginFailsBeforeAnyDatabaseLookup() {
        properties.setAdminLogin("");

        assertThatThrownBy(() -> runner.run(mock(ApplicationArguments.class)))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("BOOTSTRAP_ADMIN_LOGIN");

        verifyNoInteractions(userRepository, employeeRepository, roleRepository, userRoleRepository);
    }

    @Test
    void existingAdminDoesNotRequireBootstrapSecret() {
        when(userRepository.existsByLoginAccount("bootstrap-admin-test")).thenReturn(true);

        runner.run(mock(ApplicationArguments.class));

        verify(employeeRepository, never()).findByCode("ADMIN");
        verify(passwordEncoder, never()).encode(org.mockito.ArgumentMatchers.anyString());
        verify(userRepository, never()).findByLoginAccount("bootstrap-admin-test");
        verify(userRepository, never()).save(org.mockito.ArgumentMatchers.any());
    }

    @Test
    void emptyDatabaseFailsClosedWithoutStrongOneTimeSecret() {
        when(userRepository.existsByLoginAccount("bootstrap-admin-test")).thenReturn(false);
        when(employeeRepository.findByCode("ADMIN")).thenReturn(Optional.of(new Employee()));

        assertThatThrownBy(() -> runner.run(mock(ApplicationArguments.class)))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("BOOTSTRAP_ADMIN_PASSWORD");

        verify(passwordEncoder, never()).encode(org.mockito.ArgumentMatchers.anyString());
    }
}
