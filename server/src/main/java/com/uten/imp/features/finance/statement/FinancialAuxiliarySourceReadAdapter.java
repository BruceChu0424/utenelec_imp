package com.uten.imp.features.finance.statement;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.FinancialAuxiliarySourceReadPort;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.*;
import com.uten.imp.security.CurrentAuthorityGuard;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.util.*;

/** Purpose-bound read for a different accounting reviewer; the accounting batch verifies the returned owner. */
@Service @RequiredArgsConstructor
public class FinancialAuxiliarySourceReadAdapter implements FinancialAuxiliarySourceReadPort {
    private final JdbcTemplate db;
    private final ObjectMapper json;
    private final FinanceDocumentAccessPolicy access;
    @Override @Transactional(readOnly=true,noRollbackFor=ApiException.class)
    public Source readForAccounting(UUID sourceId) {
        CurrentAuthorityGuard.requireAll("finance_report:view","finance_post:execute");FinanceCompanyReportAccess.require(access);
        if(sourceId==null)throw new ApiException(ErrorCode.VALIDATION_FAILED,"请选择原辅助明细资料批次");
        var rows=db.queryForList("SELECT actor_id,kind,preview::text,sha256 FROM finance_statement_source_reviews WHERE id=?",sourceId);
        if(rows.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"原辅助明细资料不存在");
        var stored=rows.getFirst();FinanceAuxiliaryImportService.Preview source;
        try{source=json.readValue(stored.get("preview").toString(),FinanceAuxiliaryImportService.Preview.class);}
        catch(Exception error){throw new IllegalStateException("原辅助明细预览不能完整读取",error);}
        if(!sourceId.equals(source.importId())||!source.sha256().equals(stored.get("sha256"))||
                !(source.receivable()?"AUXILIARY_RECEIVABLE":"AUXILIARY_PAYABLE").equals(stored.get("kind")))
            throw new ApiException(ErrorCode.CONFLICT,"原辅助明细批次身份不一致，请核对原文件");
        List<Row> detail=source.rows().stream().map(row->new Row(row.sourceRow(),row.accountCode(),row.accountName(),row.partyCode(),row.partyName(),
                row.openingDebit(),row.openingCredit(),row.debit(),row.credit(),row.closingDebit(),row.closingCredit(),row.currencyId(),row.currencyChartVersion())).toList();
        return new Source(sourceId,(UUID)stored.get("actor_id"),source.receivable()?"CUSTOMER":"SUPPLIER",source.sourceSystem(),source.currencyId(),
                source.dateFrom(),source.dateTo(),source.sha256(),source.columnContractVersion()==com.uten.imp.common.importing.ImportColumnGuard.VERSION
                        &&source.issues().isEmpty()&&source.rows().stream().allMatch(row->row.currencyId()!=null),detail);
    }
}
