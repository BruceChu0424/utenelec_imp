package com.uten.imp.features.finance;
import com.uten.imp.common.finance.AccountingExpensePurpose;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.*;
import java.util.*;

/** Minimal business references, not account balances or unrestricted master-data editing. */
@RestController @RequiredArgsConstructor
@RequestMapping("/api/finance/accounting-expense-styles")
public class FinanceAccountingExpenseStyleController {
    private final EntityManager em;
    @GetMapping @Transactional(readOnly=true)
    @PreAuthorize("hasAnyAuthority('finance_expense:view','finance_expense:create','finance_expense:edit','expense:pay','finance_asset:edit','finance_application:review','payment_style:view')")
    public Map<String,Object> references(@RequestParam(required=false)String postingPurpose){return Map.of("items",FinanceAccountingExpenseStyles.references(em,AccountingExpensePurpose.parse(postingPurpose)));}
}
