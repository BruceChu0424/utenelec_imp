package com.uten.imp.features.org;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.platformcolumns.*;
import com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter.FactDefinition;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeQueryService;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.department.DepartmentService;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import java.util.List;
import java.util.Set;

@Configuration
@RequiredArgsConstructor
public class OrgPlatformColumnAdapters {
    private final EntityManager em;private final ObjectMapper json;private final SecurityContextCurrentUser current;
    private final EmployeeQueryService employees;private final DepartmentService departments;
    @Bean public PlatformColumnResourceAdapter employeePlatformColumns() {
        return new RetainedPlatformColumnAdapter(new DocumentPlatformColumnAdapter("employee","员工资料",current,em,json,
                Set.of("employee:view"),Set.of("employee:edit"),Set.of("employee:compensation:view"),Employee.class,null,employees::detail,
                (id,record)->true,List.of(new FactDefinition("probationMonths","试用月数",false),new FactDefinition("renewCount","续签次数",false),
                    new FactDefinition("baseSalary","基本工资",true),new FactDefinition("perfSalary","绩效工资",true),new FactDefinition("allowanceStandard","津贴标准",true))));
    }
    @Bean public PlatformColumnResourceAdapter departmentPlatformColumns() {
        return new RetainedPlatformColumnAdapter(new DocumentPlatformColumnAdapter("department","部门资料",current,em,json,
                Set.of("department:view"),Set.of("department:edit"),Set.of(),Department.class,null,departments::detail,(id,record)->true,
                List.of(new FactDefinition("headcount","编制人数",false),new FactDefinition("employeeCount","在职人数",false),new FactDefinition("childCount","下级部门数",false))));
    }
}
