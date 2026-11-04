package com.uten.imp.features.finance.report;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.files.document.*;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.*;
import com.uten.imp.security.*;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.util.*;

/** Immutable input evidence for cost/asset templates; preview never creates accounting or stock facts. */
@Service @RequiredArgsConstructor
public class FinanceTemplateSourceService {
    private static final Set<String> ASSETS=Set.of("depreciation","amortization","depreciationCompleted");
    private static final Set<String> COSTS=Set.of("copperFee","copperDetail","plasticUsage","plasticIssue","plasticReturn","plasticFinished","salesCostSummary","otherReceivableStatement");
    private static final Set<String> STATEMENTS=Set.of("subcontractStatement","supplierStatement","clientStatement");
    private final JdbcTemplate db;private final ObjectMapper json;private final ImmutableDocumentStore store;
    private final SecurityContextCurrentUser current;private final FinanceDocumentAccessPolicy access;private final TxSessionVars tx;
    private void require(String template,boolean edit){
        if(ASSETS.contains(template))CurrentAuthorityGuard.requireAll("finance_asset:view",edit?"finance_asset:edit":"finance_asset:view");
        else if(COSTS.contains(template)||STATEMENTS.contains(template)){CurrentAuthorityGuard.requireAll("finance_report:view");FinanceCompanyReportAccess.require(access);if(edit)CurrentAuthorityGuard.requireAll("payment_style:edit");}
        else throw new ApiException(ErrorCode.VALIDATION_FAILED,"原表入口不正确");
    }
    @Transactional
    public FinanceTemplateSourceReader.Preview preview(String template,String period,String name,byte[] bytes,boolean assetEndpoint) {
        return preview(template,period,name,bytes,assetEndpoint,null);
    }
    @Transactional
    public FinanceTemplateSourceReader.Preview preview(String template,String period,String name,byte[] bytes,boolean assetEndpoint,String sourceSheet) {
        require(template,true);if(assetEndpoint!=ASSETS.contains(template))throw new ApiException(ErrorCode.VALIDATION_FAILED,"原表上传入口不匹配");
        FinanceTemplateSourceReader.period(period);
        if(name==null||name.isBlank()||name.length()>500)throw new ApiException(ErrorCode.VALIDATION_FAILED,"请保留原文件名");
        if(sourceSheet!=null&&(sourceSheet.isBlank()||sourceSheet.length()>500||sourceSheet.chars().anyMatch(Character::isISOControl)))throw new ApiException(ErrorCode.VALIDATION_FAILED,"请按原名选择工作表");
        String selection=Objects.toString(sourceSheet,"");
        tx.bind();String hash=ImmutableDocumentStore.digest(bytes);
        db.query("SELECT pg_advisory_xact_lock(hashtextextended(?,996))",rs->{},current.requireId()+":"+template+":"+period+":"+hash+":"+selection);
        var old=db.queryForList("SELECT preview::text FROM finance_template_sources WHERE actor_id=? AND template_key=? AND period=? AND sha256=? AND source_selection=?",String.class,current.requireId(),template,period,hash,selection);
        if(!old.isEmpty())return decode(old.getFirst());
        var profile=assetEndpoint?DocumentIntakeProfile.FINANCIAL_ASSET:DocumentIntakeProfile.FINANCIAL_TEMPLATE;
        UUID id=UUID.randomUUID();var preview=FinanceTemplateSourceReader.read(id,template,period,name,hash,bytes,profile,sourceSheet);
        String content=DocumentSniffer.sniff(bytes,name)==DocumentKind.XLS?"application/vnd.ms-excel":"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
        var reference=store.save(assetEndpoint?"FINANCE_ASSET_TEMPLATE":STATEMENTS.contains(template)?"FINANCE_STATEMENT_TEMPLATE":"FINANCE_COST_TEMPLATE",name,content,bytes,profile);
        db.update("INSERT INTO finance_template_sources(id,actor_id,template_key,period,source_name,sha256,storage_provider,storage_key,storage_version,storage_size,preview,source_selection) VALUES(?,?,?,?,?,?,?,?,?,?,?::jsonb,?)",
                id,current.requireId(),template,period,name,hash,reference.provider(),reference.key(),reference.version(),reference.size(),encode(preview),selection);return preview;
    }
    @Transactional(readOnly=true)
    public FinanceTemplateSourceReader.Preview get(UUID id) {
        var rows=db.queryForList("SELECT template_key,preview::text FROM finance_template_sources WHERE id=? AND actor_id=?",id,current.requireId());
        if(rows.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"原表来源不存在或不属于当前账号");
        require(rows.getFirst().get("template_key").toString(),false);return decode(rows.getFirst().get("preview").toString());
    }
    private String encode(Object v){try{return json.writeValueAsString(v);}catch(Exception e){throw new IllegalStateException("原表来源编码失败",e);}}
    private FinanceTemplateSourceReader.Preview decode(String v){try{return json.readValue(v,FinanceTemplateSourceReader.Preview.class);}catch(Exception e){throw new IllegalStateException("原表来源记录无效",e);}}
}
