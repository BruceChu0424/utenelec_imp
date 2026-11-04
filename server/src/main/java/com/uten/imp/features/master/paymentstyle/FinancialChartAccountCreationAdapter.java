package com.uten.imp.features.master.paymentstyle;

import com.uten.imp.application.port.FinancialChartAccountCreationPort;
import com.uten.imp.features.master.paymentstyle.dto.PaymentStyleSaveRequest;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.UUID;

@Component
@RequiredArgsConstructor
public class FinancialChartAccountCreationAdapter implements FinancialChartAccountCreationPort {
    private final PaymentStyleService styles;
    @Override public UUID create(String externalCode,String name,String category) {
        var request=new PaymentStyleSaveRequest();
        // The original financial caption remains in the chart. This internal caption distinguishes
        // the posting identity from a legacy category with the same name and cannot claim its role.
        request.setName(externalCode+" "+name);request.setCategory(category);
        return styles.create(request).getId();
    }
}
