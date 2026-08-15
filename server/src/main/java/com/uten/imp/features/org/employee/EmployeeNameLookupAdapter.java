package com.uten.imp.features.org.employee;

import com.uten.imp.application.port.EmployeeNameLookupPort;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/** Organization-owned read adapter for employee display names. */
@Service
@RequiredArgsConstructor
public class EmployeeNameLookupAdapter implements EmployeeNameLookupPort {

    private final EmployeeRepository repository;

    @Override
    @Transactional(readOnly = true)
    public Map<UUID, String> findNames(Set<UUID> employeeIds) {
        if (employeeIds.isEmpty()) {
            return Map.of();
        }
        return repository.findAllById(employeeIds).stream()
                .collect(Collectors.toMap(Employee::getId, Employee::getFullName));
    }

    @Override
    @Transactional(readOnly = true)
    public Optional<String> findName(UUID employeeId) {
        return repository.findById(employeeId).map(Employee::getFullName);
    }
}
