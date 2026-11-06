package com.uten.imp.common.numeric;

import com.uten.imp.application.port.BusinessNumericInputEvidencePort;
import com.uten.imp.application.port.BusinessNumericInputEvidencePort.Capture;
import com.uten.imp.application.port.BusinessNumericInputEvidencePort.Unit;
import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.math.BigDecimal;
import java.util.Map;
import java.util.UUID;

/** One private, same-action kilogram capture for native input and authorized draft copies. */
public final class DocumentWeightEvidence {
    private DocumentWeightEvidence() { }
    public static void capture(BusinessNumericInputEvidencePort evidence,String kind,UUID document,UUID item,
                               String field,BigDecimal raw,BigDecimal adopted) {
        if(raw==null)return;
        if(evidence==null)throw new ApiException(ErrorCode.CONFLICT,"当前无法保存原实称重量依据，请保留输入");
        var used=raw.stripTrailingZeros().scale()>24?BusinessPrecisionContext.usedChoices().get("weight.kg-field"):null;
        var unit=new Unit("WEIGHT","KG",null);
        evidence.record(new Capture(kind,document,item,field,"1",raw,unit,adopted,unit,
                used==null?Map.of():Map.of("weight.kg-field",used)));
    }
}
