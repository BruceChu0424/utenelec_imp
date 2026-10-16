package com.uten.imp.features.org.employee;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface EmploymentHistoryRepository extends JpaRepository<EmploymentHistory, UUID> {

    List<EmploymentHistory> findByEmployeeIdOrderByEventDateDesc(UUID employeeId);

    /** 先应用更正再求最新；禁止按原始入职日期排序后才替换日期。 */
    @Query(value = "SELECT max(event_date) FROM employment_history_effective WHERE employee_id=:employeeId", nativeQuery = true)
    Optional<LocalDate> findLatestEffectiveEventDate(@Param("employeeId") UUID employeeId);
}
