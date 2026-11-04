package com.uten.imp.features.stock.weight;

import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.finance.BusinessPrecisionRequiredException;

import com.uten.imp.application.port.BusinessNumericInputEvidencePort;
import com.uten.imp.application.port.BusinessNumericInputEvidencePort.Capture;
import com.uten.imp.application.port.BusinessNumericInputEvidencePort.Unit;
import com.uten.imp.features.stock.dto.WeightInput;
import com.uten.imp.features.stock.weight.WeightMath;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.math.BigDecimal;
import java.util.Map;
import java.util.UUID;

/** Receipt weight is a captured kilogram fact; zero and unknown remain distinct. */
public final class DocumentWeightAdoption {
    private DocumentWeightAdoption() { }
    public static BigDecimal adopt(BigDecimal raw){
        return adopt(raw,"收货实称重量");
    }
    public static BigDecimal adopt(BigDecimal raw,String label){
        WeightInput.rawKg(raw,label);
        if(raw==null)return null;
        BigDecimal adopted=WeightMath.normalizeInput(raw);
        if(raw.signum()>0&&adopted.signum()==0)
            throw new BusinessPrecisionRequiredException("weight.kg-field","本次千克重量记录：所选精度会丢失正实称重量，请明确重新选择",24,"PRECISION_LIMIT",true);
        return adopted;
    }
    public static void capture(BusinessNumericInputEvidencePort evidence,String kind,UUID document,UUID item,BigDecimal raw,BigDecimal adopted){
        capture(evidence,kind,document,item,"actualWeightKg",raw,adopted);
    }
    public static void capture(BusinessNumericInputEvidencePort evidence,String kind,UUID document,UUID item,String field,BigDecimal raw,BigDecimal adopted){
        if(raw==null)return;
        if(evidence==null)throw new ApiException(ErrorCode.CONFLICT,"当前无法保存原实称重量依据，请保留输入");
        var used=raw.stripTrailingZeros().scale()>24?BusinessPrecisionContext.usedChoices().get("weight.kg-field"):null;
        var unit=new Unit("WEIGHT","KG",null);
        evidence.record(new Capture(kind,document,item,field,"1",raw,unit,adopted,unit,
                used==null?Map.of():Map.of("weight.kg-field",used)));
    }
}
