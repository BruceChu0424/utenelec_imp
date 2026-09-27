package com.uten.imp.features.auth;

import com.uten.imp.config.props.BootstrapProperties;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.boot.ApplicationArguments;
import org.springframework.security.crypto.password.PasswordEncoder;

import java.util.Optional;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class BootstrapRunnerTest {

    private final UserAccountRepository userRepository = mock(UserAccountRepository.class);
    private final EmployeeRepository employeeRepository = mock(EmployeeRepository.class);
    private final PasswordEncoder passwordEncoder = mock(PasswordEncoder.class);
    private final BootstrapProperties properties = new BootstrapProperties();
    private final BootstrapRunner runner = new BootstrapRunner(
            userRepository,
            employeeRepository,
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

        verifyNoInteractions(userRepository, employeeRepository);
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
    void emptyDatabaseFailsClosedWithoutOneTimeSecret() {
        when(userRepository.existsByLoginAccount("bootstrap-admin-test")).thenReturn(false);
        when(employeeRepository.findByCode("ADMIN")).thenReturn(Optional.of(new Employee()));

        assertThatThrownBy(() -> runner.run(mock(ApplicationArguments.class)))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("BOOTSTRAP_ADMIN_PASSWORD");

        verify(passwordEncoder, never()).encode(org.mockito.ArgumentMatchers.anyString());
    }

    @ParameterizedTest
    @MethodSource("nonBlankBootstrapPasswords")
    void initialAdminAcceptsShortOrLongPasswordsWithoutChangingTheValue(String password) {
        properties.setAdminPassword(password);
        Employee employee = new Employee();
        when(employeeRepository.findByCode("ADMIN")).thenReturn(Optional.of(employee));
        when(passwordEncoder.encode(password)).thenReturn("encoded-initial-password");

        runner.run(mock(ApplicationArguments.class));

        verify(passwordEncoder).encode(password);
        verify(userRepository).save(argThat(user ->
                "encoded-initial-password".equals(user.getPasswordHash())
                        && user.isMustChangePassword()
                        && user.isSuperAdmin()
                        && employee.getId().equals(user.getEmployeeId())));
    }

    private static Stream<String> nonBlankBootstrapPasswords() {
        return Stream.of("1", "a", "中", "x".repeat(129));
    }

    @ParameterizedTest
    @ValueSource(strings = {" ", "\t\r\n"})
    void emptyDatabaseRejectsWhitespaceOnlyOneTimeSecret(String password) {
        properties.setAdminPassword(password);
        when(employeeRepository.findByCode("ADMIN")).thenReturn(Optional.of(new Employee()));

        assertThatThrownBy(() -> runner.run(mock(ApplicationArguments.class)))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("BOOTSTRAP_ADMIN_PASSWORD");

        verifyNoInteractions(passwordEncoder);
        verify(userRepository, never()).save(org.mockito.ArgumentMatchers.any());
    }
}
