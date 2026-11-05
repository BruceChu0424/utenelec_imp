package com.uten.imp.features.purchase.common;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.Map;
import java.util.UUID;
import java.math.BigDecimal;

/** Saves only the policy actually used by the shared money calculation. */
@Service
@RequiredArgsConstructor
public class ProcurementReferencePricePolicyService {
    private final JdbcTemplate jdbc;
    private final ObjectMapper json;

    @Transactional(propagation=Propagation.MANDATORY)
    public void adoptSavedOrder(String kind,UUID orderId) {
        if(!"PURCHASE".equals(kind)&&!"SUBCONTRACT".equals(kind)||orderId==null)
            throw new IllegalArgumentException("An actual saved procurement order is required");
        String used;
        try {used=json.writeValueAsString(Map.of("version",1,"choices",BusinessPrecisionContext.usedChoices()));}
        catch(JsonProcessingException error){throw new IllegalStateException("Actual reference-price policy cannot be encoded",error);}
        Integer adopted=jdbc.queryForObject("SELECT fn_adopt_procurement_reference_price_policy(?,?,CAST(? AS jsonb))",Integer.class,kind,orderId,used);
        if(adopted==null)throw new IllegalStateException("Saved reference-price policy was not verified");
    }

    @Transactional(propagation=Propagation.MANDATORY,readOnly=true)
    public void requireSavedOrder(String kind,UUID orderId) {
        String table=switch(kind){case "PURCHASE"->"purchase_order_items";case "SUBCONTRACT"->"subcontract_order_items";default->throw new IllegalArgumentException("Unsupported procurement owner");};
        Boolean valid=jdbc.queryForObject("SELECT COALESCE(bool_and(fn_procurement_reference_price_matches(to_jsonb(i))),false) FROM "+table+" i WHERE order_id=? AND NOT is_deleted",Boolean.class,orderId);
        if(!Boolean.TRUE.equals(valid))throw new ApiException(ErrorCode.VALIDATION_FAILED,"原参考单价缺少与原总金额、数量一致的保存采用事实，请保留原输入核对原单");
    }

    public static BigDecimal savedBaseAmount(BigDecimal quantity,BigDecimal price,BigDecimal totalInput) {
        return totalInput==null?MoneyPolicy.orderBaseAmount(quantity,price,null):MoneyPolicy.totalAmountInput(totalInput);
    }
}
