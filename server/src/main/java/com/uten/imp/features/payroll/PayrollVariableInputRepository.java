package com.uten.imp.features.payroll;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Collection;
import java.util.List;
import java.util.UUID;

public interface PayrollVariableInputRepository extends JpaRepository<PayrollVariableInput, UUID> {

    @Query("""
            SELECT v FROM PayrollVariableInput v
            WHERE v.payrollYear = :year
              AND v.payrollMonth = :month
              AND v.employeeId IN :employeeIds
            """)
    List<PayrollVariableInput> findForPeriod(@Param("year") short year,
                                             @Param("month") short month,
                                             @Param("employeeIds") Collection<UUID> employeeIds);
}
