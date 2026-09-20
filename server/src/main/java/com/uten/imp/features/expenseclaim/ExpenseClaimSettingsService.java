package com.uten.imp.features.expenseclaim;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimSettingsDto;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
@RequiredArgsConstructor
public class ExpenseClaimSettingsService {
    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;

    @Transactional(readOnly=true)
    public ExpenseClaimSettingsDto get() {
        var user=currentUser.get().orElseThrow(()->new ApiException(ErrorCode.UNAUTHORIZED));
        if(user.isVisitor() || user.getEmployeeId()==null || (!user.isSuperAdmin()
                && user.getPermissions().stream().noneMatch(p->java.util.Set.of(
                        "expense:apply","expense:approve","expense:pay","expense:settings").contains(p)))) {
            throw new ApiException(ErrorCode.FORBIDDEN);
        }
        Object[] row=(Object[])em.createNativeQuery("SELECT company_name, company_tax_no, submission_guide, require_invoice, version FROM expense_claim_settings WHERE id=1").getSingleResult();
        return new ExpenseClaimSettingsDto((String)row[0],(String)row[1],(String)row[2],(Boolean)row[3],((Number)row[4]).longValue());
    }

    @Transactional
    public ExpenseClaimSettingsDto update(ExpenseClaimSettingsDto input) {
        var user=currentUser.get().orElseThrow(()->new ApiException(ErrorCode.UNAUTHORIZED));
        if(user.isVisitor() || user.getEmployeeId()==null || (!user.isSuperAdmin()
                && !user.getPermissions().contains("expense:settings"))) throw new ApiException(ErrorCode.FORBIDDEN);
        String tax=input.companyTaxNo()==null?null:input.companyTaxNo().trim().toUpperCase(java.util.Locale.ROOT);
        if(tax!=null && tax.isEmpty()) tax=null;
        if(input.companyName()==null || input.companyName().isBlank() || input.companyName().trim().length()>200
                || input.version()==null || input.version()<0
                || (tax!=null && !tax.matches("[0-9A-Z]{15}|[0-9A-Z]{18}|[0-9A-Z]{20}")))
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"公司名称、纳税人识别号或版本无效");
        tx.bind();
        int rows=em.createNativeQuery("""
                UPDATE expense_claim_settings SET company_name=:name, company_tax_no=:tax,
                    submission_guide=:guide, require_invoice=:required, version=version+1,
                    updated_at=now(), updated_by=:actor WHERE id=1 AND version=:version
                """).setParameter("name",input.companyName().trim()).setParameter("tax",tax)
                .setParameter("guide",input.submissionGuide()).setParameter("required",input.requireInvoice())
                .setParameter("actor",user.getEmployeeId()).setParameter("version",input.version()).executeUpdate();
        if(rows!=1) throw new ApiException(ErrorCode.CONFLICT,"报销设置已更新，请刷新后重试");
        return get();
    }
}
