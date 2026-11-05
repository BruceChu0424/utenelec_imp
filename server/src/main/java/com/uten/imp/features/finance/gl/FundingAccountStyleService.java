package com.uten.imp.features.finance.gl;

import com.uten.imp.application.port.FundingAccountStylePort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.util.List;
import java.util.UUID;

/** The same resolved BS_1 scope as the balance sheet, including explicit overrides of cash/bank roots. */
@Service
@RequiredArgsConstructor
public class FundingAccountStyleService implements FundingAccountStylePort {
    private final EntityManager em;

    @Override
    @Transactional(readOnly=true)
    public List<Choice> choices() {
        requireUnambiguous();
        return NativeQueryResults.objectArrayRows(em.createNativeQuery(selectionSql()+" ORDER BY style.path,style.code,style.id"))
                .stream().map(row->new Choice((UUID)row[0],row[1]==null?null:((Number)row[1]).intValue(),
                        (String)row[2],(String)row[3],(String)row[4])).toList();
    }

    @Override
    @Transactional(readOnly=true)
    public void requireSelectable(UUID styleId) {
        if(styleId==null)throw invalid();
        requireUnambiguous();
        if(NativeQueryResults.objectArrayRows(em.createNativeQuery(selectionSql()+" AND style.id=:id")
                .setParameter("id",styleId)).size()!=1)throw invalid();
    }

    private void requireUnambiguous() {
        GlReportSourceScopes.assertUnambiguous(em);
        var conflicts=NativeQueryResults.objectArrayRows(em.createNativeQuery(FinancialStatementService.scope("BALANCE")+"""
                SELECT style.code,style.name,string_agg(resolved.line_key,',' ORDER BY resolved.line_key)
                FROM resolved JOIN payment_styles style ON style.id=resolved.style_id
                GROUP BY style.id,style.code,style.name
                HAVING count(*)>1 AND bool_or(resolved.line_key='BS_1')
                ORDER BY style.code,style.id LIMIT 1
                """));
        if(!conflicts.isEmpty())throw new ApiException(ErrorCode.CONFLICT,
                "资金记账对应存在冲突：科目「%s」（%s）同时归入%s，请先核对财务取数设置。"
                        .formatted(conflicts.getFirst()[1],conflicts.getFirst()[0],conflicts.getFirst()[2]));
    }

    private static String selectionSql() {
        return FinancialStatementService.scope("BALANCE")+"""
                SELECT style.id,style.legacy_id,style.code,style.name,style.path
                FROM payment_styles style
                JOIN resolved ON resolved.style_id=style.id AND resolved.line_key='BS_1'
                WHERE NOT style.is_deleted AND style.status='使用' AND style.category='ACCOUNT'
                  AND NOT EXISTS(SELECT 1 FROM payment_styles child WHERE child.parent_id=style.id AND NOT child.is_deleted)
                """;
    }
    private static ApiException invalid() {
        return new ApiException(ErrorCode.VALIDATION_FAILED,
                "请选择已明确归入货币资金的可用末级科目；请先在财务科目与取数设置中维护资金记账对应。");
    }
}
