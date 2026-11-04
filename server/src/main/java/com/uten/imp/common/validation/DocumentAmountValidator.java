package com.uten.imp.common.validation;

import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.ApiException;
import jakarta.validation.ConstraintValidator;
import jakarta.validation.ConstraintValidatorContext;
import java.math.BigDecimal;

public final class DocumentAmountValidator implements ConstraintValidator<DocumentAmount,BigDecimal> {
    @Override public boolean isValid(BigDecimal value,ConstraintValidatorContext context){
        if(value==null)return true;
        try{FinancialExactAmount.require(value,"金额");return true;}catch(ApiException outsideNativeBoundary){return false;}
    }
}
