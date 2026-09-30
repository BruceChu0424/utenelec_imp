package com.uten.imp.features.payroll;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.platformcolumns.*;
import com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter.FactDefinition;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import java.util.List;
import java.util.Set;

@Configuration
@RequiredArgsConstructor
public class PayrollPlatformColumnAdapters {
    private final PayrollService payroll;private final SecurityContextCurrentUser current;private final ObjectMapper json;
    @Bean public PlatformColumnResourceAdapter payrollSlipPlatformColumns() {
        return new ReadOnlyPlatformColumnAdapter("payroll_slip","工资条",current,json,
                Set.of("payroll:view:self","payroll:view:all"),Set.of("payroll:view:self","payroll:view:all"),payroll::getSlip,
                List.of(new FactDefinition("grossIncome","应发工资",true),new FactDefinition("totalDeduction","扣款合计",true),new FactDefinition("netIncome","实发工资",true)));
    }
}
