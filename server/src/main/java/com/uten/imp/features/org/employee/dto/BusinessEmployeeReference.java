package com.uten.imp.features.org.employee.dto;

import java.util.UUID;

/** Only business identity labels; never an employee record or HR-detail projection. */
public record BusinessEmployeeReference(UUID id,String code,String fullName,UUID departmentId,
        String departmentName,String positionName,String status,String accountStatus) { }
