package com.uten.imp.features.finance.gl;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.*;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.*;
import com.uten.imp.security.*;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.*;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;

/** Unique native account resolver. A new correspondence never relabels an existing debt. */
@Service @RequiredArgsConstructor
public class NativeFinancialPostingAccountService implements NativeFinancialPostingAccountPort,FinancialFrozenDebtReadPort {
    private final JdbcTemplate db;
    private final jakarta.persistence.EntityManager em;
    private final ObjectMapper json;
    private final FinancialChartCurrencyReadPort currencies;
    private final FinancialAuxiliaryValidationPort auxiliaries;
    private final SecurityContextCurrentUser current;
    private final TxSessionVars tx;
    private final FinanceDocumentAccessPolicy access;
    @org.springframework.beans.factory.annotation.Autowired private org.springframework.beans.factory.ObjectProvider<FinanceControlledJournalService> controlledJournals;
    @org.springframework.beans.factory.annotation.Autowired private org.springframework.beans.factory.ObjectProvider<NativeLegacyOpeningReadPort> legacyOpenings;
    public record Configuration(UUID requestId,String role,UUID originalCurrencyId,Party party,LocalDate effectiveFrom,
            boolean enabled,UUID styleId,String accountCode,UUID accountingCurrencyId,UUID auxiliaryId,String sourceReference) { }
    public record DebtCorrespondence(UUID requestId,UUID ledgerId,UUID entryId,String accountCode,UUID auxiliaryId,String sourceReference) { }

    private void readAccess(){CurrentAuthorityGuard.requireAll("finance_report:view");FinanceCompanyReportAccess.require(access);}
    private void writeAccess(){readAccess();CurrentAuthorityGuard.requireAll("payment_style:edit");}
    private void lock(boolean shared){db.query("SELECT "+(shared?"pg_advisory_xact_lock_shared":"pg_advisory_xact_lock")+"(hashtextextended('uten:native-financial-posting',0))",rs->{});}

    @Transactional(readOnly=true)
    public Map<String,Object> choices(){
        readAccess();return Map.of("roles",db.queryForList("SELECT role_key AS id,description AS name,required_category AS category FROM system_posting_style_roles ORDER BY role_key"),"currencies",currencies.choices());
    }
    @Transactional(readOnly=true)
    public List<Map<String,Object>> accountChoices(String role){
        readAccess();var rows=db.queryForList("""
            SELECT c.code,c.name,p.id AS style_id,p.name AS style_name FROM finance_chart_codes c
            JOIN finance_chart_code_styles m ON m.code=c.code JOIN payment_styles p ON p.id=m.style_id
            JOIN system_posting_style_roles r ON r.role_key=? AND r.required_category=p.category
            WHERE p.status='使用' AND NOT p.is_deleted ORDER BY c.sort_order,c.code
            """,role);
        var refs=currencies.read(new LinkedHashSet<>(rows.stream().map(r->r.get("code").toString()).toList()));
        for(var row:rows){var ref=refs.get(row.get("code").toString());row.put("accounting_currency_id",ref==null?null:ref.currencyId());row.put("source_currency_name",ref==null?null:ref.sourceCurrencyName());}
        return rows;
    }

    @Transactional(readOnly=true)
    public Map<String,Object> configurations(int page,int size){
        readAccess();int s=Math.max(1,Math.min(200,size)),p=Math.max(1,page);
        long total=db.queryForObject("SELECT count(*) FROM finance_native_posting_configurations",Long.class);
        return Map.of("items",db.queryForList("SELECT * FROM finance_native_posting_configurations ORDER BY created_at DESC,id LIMIT ? OFFSET ?",s,(long)(p-1)*s),"page",p,"size",s,"total",total,"totalPages",(total+s-1)/s);
    }
    @Transactional
    public Map<String,Object> submit(Configuration input){
        writeAccess();if(input==null||input.requestId()==null||input.effectiveFrom()==null||input.role()==null||input.role().isBlank()
                ||input.styleId()==null||input.accountCode()==null||input.accountingCurrencyId()==null||input.sourceReference()==null
                ||input.sourceReference().isBlank()||input.sourceReference().length()>2000)throw invalid("请填写用途、真实币别适用范围、科目对应、生效日期和依据");
        tx.bind();lock(false);String fingerprint=hash(encode(input));
        var replay=db.queryForList("SELECT * FROM finance_native_posting_configurations WHERE request_id=?",input.requestId());
        if(!replay.isEmpty()){var row=replay.getFirst();if(!fingerprint.equals(row.get("payload_hash"))||!current.requireId().equals(row.get("created_by")))throw conflict("该请求已使用，请保留原参数核对提交结果");return row;}
        if(input.party()!=null&&(input.party().id()==null||!Set.of("CUSTOMER","SUPPLIER","EMPLOYEE","OTHER").contains(input.party().role())))throw invalid("请选择明确的往来对象类别及真实编号");
        validateConfigured(input);
        String partyRole=input.party()==null?null:input.party().role();UUID partyId=input.party()==null?null:input.party().id();
        Long version=db.queryForObject("SELECT COALESCE(max(configuration_version),0)+1 FROM finance_native_posting_configurations WHERE role_key=? AND original_currency_id IS NOT DISTINCT FROM ? AND party_role IS NOT DISTINCT FROM ? AND party_id IS NOT DISTINCT FROM ? AND effective_from=?",Long.class,input.role(),input.originalCurrencyId(),partyRole,partyId,input.effectiveFrom());
        UUID id=UUID.randomUUID();db.update("""
            INSERT INTO finance_native_posting_configurations(id,request_id,payload_hash,role_key,original_currency_id,party_role,party_id,
              effective_from,configuration_version,enabled,style_id,account_code,accounting_currency_id,auxiliary_id,source_reference,created_by)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,id,input.requestId(),fingerprint,input.role(),input.originalCurrencyId(),partyRole,partyId,input.effectiveFrom(),version,input.enabled(),input.styleId(),input.accountCode(),input.accountingCurrencyId(),input.auxiliaryId(),input.sourceReference().strip(),current.requireId());
        return db.queryForMap("SELECT * FROM finance_native_posting_configurations WHERE id=?",id);
    }
    @Transactional
    public Map<String,Object> approve(UUID id){
        writeAccess();CurrentAuthorityGuard.requireAll("finance_post:execute");tx.bind();lock(false);
        var rows=db.queryForList("SELECT * FROM finance_native_posting_configurations WHERE id=? FOR UPDATE",id);if(rows.size()!=1)throw invalid("原生科目对应版本不存在");
        var row=rows.getFirst();if("APPROVED".equals(row.get("status")))return row;
        if(current.requireId().equals(row.get("created_by")))throw conflict("科目对应须由另一名财务审核人确认");
        validateConfigured(configuration(row));
        db.update("UPDATE finance_native_posting_configurations SET status='APPROVED',approved_by=?,approved_at=now() WHERE id=? AND status='DRAFT'",current.requireId(),id);
        return db.queryForMap("SELECT * FROM finance_native_posting_configurations WHERE id=?",id);
    }
    @Transactional(readOnly=true)
    public Map<String,Object> debtCorrespondencePreview(UUID ledgerId){
        readAccess();CurrentAuthorityGuard.requireAll("ar_ap_ledger:view");var ledger=reviewableLedger(ledgerId);
        var result=new LinkedHashMap<String,Object>();result.put("ledgerId",ledgerId);result.put("sourceDocNo",ledger.get("source_doc_no"));result.put("postingDate",ledger.get("bill_date"));
        boolean ar="AR".equals(ledger.get("direction"));result.put("partyRole",ar?"CUSTOMER":"SUPPLIER");result.put("partyId",ledger.get(ar?"client_id":"supplier_id"));result.put("originalCurrencyId",ledger.get("currency_id"));
        result.put("originalCurrency",db.queryForMap("SELECT code,name FROM currencies WHERE id=?",ledger.get("currency_id")));
        result.put("amountOriginalText",amount(ledger,"amount_original").toPlainString());result.put("amountLocalText",amount(ledger,"amount_original_local").toPlainString());
        var entries=reviewableEntries(ledger);result.put("entries",entries);result.put("reviews",db.queryForList("SELECT id,status,source_reference,created_by,approved_by FROM finance_native_debt_correspondence_reviews WHERE ledger_id=? ORDER BY created_at DESC,id",ledgerId));
        return result;
    }
    @Transactional
    public Map<String,Object> submitDebtCorrespondence(DebtCorrespondence input){
        writeAccess();CurrentAuthorityGuard.requireAll("ar_ap_ledger:view","finance_post:execute");
        if(input==null||input.requestId()==null||input.ledgerId()==null||input.entryId()==null||input.accountCode()==null||input.sourceReference()==null||input.sourceReference().isBlank()||input.sourceReference().length()>2000)throw invalid("请选择原往来分录、明确财务科目及辅助对象，并填写核对依据");
        tx.bind();lock(false);chartLock();String fp=hash(encode(input));var existing=db.queryForList("SELECT * FROM finance_native_debt_correspondence_reviews WHERE request_id=?",input.requestId());
        if(!existing.isEmpty()){var row=existing.getFirst();if(!fp.equals(row.get("payload_hash"))||!current.requireId().equals(row.get("created_by")))throw conflict("该核对请求已使用，请保留原参数核对结果");return row;}
        var ledger=reviewableLedger(input.ledgerId());var entry=reviewableEntries(ledger).stream().filter(e->input.entryId().equals(e.get("entryId"))).findFirst().orElseThrow(()->conflict("原往来分录不存在或来源身份、金额已变化"));
        Account before=frozenArAp(input.ledgerId());if(before!=null&&before.complete())throw conflict("该往来已有完整受审科目及辅助快照，不能通过补对应改写，请走受控更正");
        if(before!=null&&before.accountCode()!=null&&!before.accountCode().equals(input.accountCode()))throw conflict("原审核已冻结财务科目代码，补对应不能替换为别的科目");
        UUID style=(UUID)entry.get("styleId");if(db.queryForObject("SELECT count(*) FROM finance_chart_code_styles WHERE code=? AND style_id=?",Integer.class,input.accountCode(),style)!=1)throw invalid("财务科目须明确对应原已记账分录的实际科目 UUID，不按名称或当前用途改配");
        var currency=currencies.read(Set.of(input.accountCode())).get(input.accountCode());if(currency==null||currency.currencyId()==null)throw invalid("请先维护该财务科目的会计属性币别");
        if(before!=null&&before.accountingCurrencyId()!=null&&!before.accountingCurrencyId().equals(currency.currencyId()))throw conflict("原审核已冻结会计币别属性，不能通过补对应改写");
        boolean ar="AR".equals(ledger.get("direction"));Party party=new Party(ar?"CUSTOMER":"SUPPLIER",(UUID)ledger.get(ar?"client_id":"supplier_id"));
        var auxiliary=postingAuxiliary(ar?"AR_CONTROL":"AP_CONTROL",input.accountCode(),currency.currencyId(),input.auxiliaryId(),party);auxiliary=lockPostingAuxiliary(input.accountCode(),currency.currencyId(),auxiliary,party);
        Account account=new Account(style,input.accountCode(),currency.currencyId(),auxiliary,(UUID)ledger.get("currency_id"),null,0,true,true,"对原真实分录独立受审补充代码/辅助证据；不新增金额、不重放业务");
        bindExistingArApEntry(input.ledgerId());
        UUID id=UUID.randomUUID();db.update("INSERT INTO finance_native_debt_correspondence_reviews(id,request_id,payload_hash,ledger_id,entry_id,account_snapshot,source_fingerprint,source_reference,created_by)VALUES(?,?,?,?,?,?::jsonb,?,?,?)",id,input.requestId(),fp,input.ledgerId(),input.entryId(),encode(account),sourceFingerprint(ledger),input.sourceReference().strip(),current.requireId());
        return db.queryForMap("SELECT * FROM finance_native_debt_correspondence_reviews WHERE id=?",id);
    }
    @Transactional
    public Map<String,Object> approveDebtCorrespondence(UUID id){
        writeAccess();CurrentAuthorityGuard.requireAll("ar_ap_ledger:view","finance_post:execute");tx.bind();lock(false);chartLock();var rows=db.queryForList("SELECT * FROM finance_native_debt_correspondence_reviews WHERE id=? FOR UPDATE",id);
        if(rows.size()!=1)throw invalid("原往来核对记录不存在");var review=rows.getFirst();if("APPROVED".equals(review.get("status")))return review;
        if(current.requireId().equals(review.get("created_by")))throw conflict("补对应须由另一名财务审核人核对原分录与辅助对象");
        var ledger=reviewableLedger((UUID)review.get("ledger_id"));if(!sourceFingerprint(ledger).equals(review.get("source_fingerprint")))throw conflict("原往来身份或原金额已变化，请保留原核对记录重新核实");
        var entry=reviewableEntries(ledger).stream().filter(e->Objects.equals(review.get("entry_id"),e.get("entryId"))).findFirst().orElseThrow(()->conflict("原分录已变化或已有辅助证据，请刷新核对"));
        Account account=decode(review.get("account_snapshot").toString(),Account.class);boolean ar="AR".equals(ledger.get("direction"));Party party=new Party(ar?"CUSTOMER":"SUPPLIER",(UUID)ledger.get(ar?"client_id":"supplier_id"));
        var checked=lockPostingAuxiliary(account.accountCode(),account.accountingCurrencyId(),account.auxiliary(),party);if(!Objects.equals(checked,account.auxiliary()))throw conflict("辅助原编号或名称快照已变化，请重新核对本次选择");
        int natural=ar?1:-1,direction=((Number)entry.get("direction")).intValue();BigDecimal original=amount(ledger,"amount_original").multiply(BigDecimal.valueOf((long)natural*direction));
        var auxiliary=account.auxiliary();db.update("""
            INSERT INTO finance_gl_entry_allocations(entry_id,allocation_no,account_code,source_account_code,auxiliary_id,currency_id,original_currency_id,
              amount_local,amount_original,auxiliary_role,party_id_snapshot,source_system,source_code,source_name,source_entry_id,source_row,source_snapshot,created_by)
            VALUES(?,1,?,?,?,?,?,?,?,?,?,?,?,?,?,1,?::jsonb,?)
            """,review.get("entry_id"),account.accountCode(),account.accountCode(),auxiliary.auxiliaryId(),account.accountingCurrencyId(),account.originalCurrencyId(),entry.get("amountLocal"),original,auxiliary.role(),auxiliary.partyId(),auxiliary.sourceSystem(),auxiliary.sourceCode(),auxiliary.sourceName(),ledger.get("id").toString(),encode(Map.of("reviewId",id,"account",account,"sourceFingerprint",review.get("source_fingerprint"))),current.requireId());
        db.update("UPDATE finance_native_debt_correspondence_reviews SET status='APPROVED',approved_by=?,approved_at=now() WHERE id=? AND status='DRAFT'",current.requireId(),id);return db.queryForMap("SELECT * FROM finance_native_debt_correspondence_reviews WHERE id=?",id);
    }
    private Map<String,Object> reviewableLedger(UUID id){var rows=db.queryForList("SELECT * FROM ar_ap_ledger WHERE id=? AND legacy_id IS NULL AND status=1 AND NOT is_deleted AND currency_id IS NOT NULL",id);if(rows.size()!=1)throw conflict("请选择具有明确原币的有效原生往来，历史导入须走原来源核对");return rows.getFirst();}
    private List<Map<String,Object>> reviewableEntries(Map<String,Object> ledger){
        return db.queryForList("""
            SELECT e.id AS "entryId",e.style_id AS "styleId",e.direction,e.amount AS "amountLocal",v.voucher_no AS "voucherNo",p.name AS "styleName"
            FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id JOIN payment_styles p ON p.id=e.style_id
            WHERE NOT e.is_deleted AND v.status=1 AND NOT v.is_deleted AND v.reversed_by_voucher_id IS NULL
              AND NOT EXISTS(SELECT 1 FROM finance_gl_voucher_evidence external WHERE external.voucher_id=v.id)
              AND NOT EXISTS(SELECT 1 FROM finance_gl_entry_allocations known WHERE known.entry_id=e.id)
              AND ((v.source_type=CASE ?::text WHEN 'AR' THEN 'AR_POST' ELSE 'AP_POST' END AND v.source_doc_id=? AND v.period=to_char(?::date,'YYYY-MM') AND e.line_no=CASE ?::text WHEN 'AR' THEN 1 ELSE 2 END)
                OR (e.source_doc_type='PROCUREMENT_AP_RECOGNITION_LINE' AND e.source_doc_id=?))
              AND e.direction*e.amount=CASE ?::text WHEN 'AR' THEN 1 ELSE -1 END * ?::numeric
            ORDER BY e.id
            """,ledger.get("direction"),ledger.get("source_doc_id"),ledger.get("bill_date"),ledger.get("direction"),ledger.get("id"),ledger.get("direction"),ledger.get("amount_original_local"));
    }
    private Configuration configuration(Map<String,Object> r){return new Configuration((UUID)r.get("request_id"),text(r,"role_key"),(UUID)r.get("original_currency_id"),r.get("party_id")==null?null:new Party(text(r,"party_role"),(UUID)r.get("party_id")),date(r.get("effective_from")),Boolean.TRUE.equals(r.get("enabled")),(UUID)r.get("style_id"),text(r,"account_code"),(UUID)r.get("accounting_currency_id"),(UUID)r.get("auxiliary_id"),text(r,"source_reference"));}
    private void validateConfigured(Configuration c){
        chartLock();
        if(c.party()!=null){String table=switch(c.party().role()){case "CUSTOMER"->"clients";case "SUPPLIER"->"suppliers";case "EMPLOYEE"->"employees";case "OTHER"->"finance_auxiliary_parties";default->throw invalid("往来对象类别不正确");};
            if(db.queryForObject("SELECT count(*) FROM "+table+" WHERE id=?",Integer.class,c.party().id())!=1)throw invalid("所选类别下的真实往来对象不存在");}
        var style=db.queryForList("SELECT p.category,p.status,p.is_deleted,r.required_category FROM payment_styles p JOIN system_posting_style_roles r ON r.role_key=? WHERE p.id=?",c.role(),c.styleId());
        if(style.size()!=1||!Objects.equals(style.getFirst().get("category"),style.getFirst().get("required_category"))||!"使用".equals(style.getFirst().get("status"))||Boolean.TRUE.equals(style.getFirst().get("is_deleted")))throw invalid("该用途所选核算类别或科目状态不正确");
        if(db.queryForObject("SELECT count(*) FROM finance_chart_code_styles WHERE code=? AND style_id=?",Integer.class,c.accountCode(),c.styleId())!=1)throw invalid("请先明确财务原科目代码与系统科目的 UUID 对应");
        var currency=currencies.read(Set.of(c.accountCode())).get(c.accountCode());if(currency==null||!Objects.equals(currency.currencyId(),c.accountingCurrencyId()))throw invalid("会计属性币别须与已核验财务科目对应一致");
        if(c.originalCurrencyId()!=null&&db.queryForObject("SELECT count(*) FROM currencies WHERE id=? AND NOT is_deleted",Integer.class,c.originalCurrencyId())!=1)throw invalid("真实交易币别不存在");
        if(c.auxiliaryId()!=null){if(c.party()==null)throw invalid("指定辅助项目时须同时指定实际往来对象");var ref=auxiliaries.validateForPosting(List.of(new FinancialAuxiliaryValidationPort.Selection(c.accountCode(),c.auxiliaryId(),c.accountingCurrencyId()))).getFirst();if(ref==null||!Objects.equals(ref.role(),c.party().role())||!Objects.equals(ref.partyId(),c.party().id()))throw invalid("辅助项目必须明确对应所选实际往来对象");}
    }

    @Override @Transactional(propagation=Propagation.MANDATORY,noRollbackFor=ApiException.class)
    public Account resolve(Request request){
        if(request==null||request.role()==null||request.postingDate()==null)throw invalid("原生过账缺少用途或真实业务日期");
        lock(true);chartLock();Party p=request.party();
        var configured=db.queryForList("""
            SELECT * FROM finance_native_posting_configurations WHERE role_key=? AND status='APPROVED' AND effective_from<=?
              AND (original_currency_id IS NULL OR original_currency_id=?)
              AND (party_id IS NULL OR (party_role=? AND party_id=?))
            ORDER BY (party_id IS NOT NULL) DESC,(original_currency_id IS NOT NULL) DESC,effective_from DESC,configuration_version DESC,id LIMIT 1
            """,request.role(),request.postingDate(),request.originalCurrencyId(),p==null?null:p.role(),p==null?null:p.id());
        if(!configured.isEmpty()&&Boolean.TRUE.equals(configured.getFirst().get("enabled"))){
            var r=configured.getFirst();Configuration c=configuration(r);validateConfigured(c);
            var ref=postingAuxiliary(request.role(),c.accountCode(),c.accountingCurrencyId(),c.auxiliaryId(),p);
            ref=lockPostingAuxiliary(c.accountCode(),c.accountingCurrencyId(),ref,p);
            return new Account(c.styleId(),c.accountCode(),c.accountingCurrencyId(),ref,request.originalCurrencyId(),(UUID)r.get("id"),((Number)r.get("configuration_version")).longValue(),false,true,"已独立审核的用途/交易币别/实际往来对应；保留版本");
        }
        UUID style=request.existingStyleId();if(style==null)style=db.queryForObject("SELECT system_posting_style_id(?)",UUID.class,request.role());
        if(style==null)return new Account(null,null,null,null,request.originalCurrencyId(),null,0,true,false,"原业务尚未选择会计用途；不得猜配或制造财务分录");
        var codes=db.queryForList("SELECT code FROM finance_chart_code_styles WHERE style_id=?",String.class,style);
        if(codes.size()!=1)return new Account(style,null,null,null,request.originalCurrencyId(),null,0,true,false,"沿原有全局用途；财务代码尚未唯一对应");
        String code=codes.getFirst();var currency=currencies.read(Set.of(code)).get(code);
        if(currency==null||currency.currencyId()==null)return new Account(style,code,null,null,request.originalCurrencyId(),null,0,true,false,"沿原有全局用途；会计属性币别待维护");
        FinancialAuxiliaryValidationPort.Ref ref;
        try{ref=postingAuxiliary(request.role(),code,currency.currencyId(),null,p);}catch(ApiException e){return new Account(style,code,currency.currencyId(),null,request.originalCurrencyId(),null,0,true,false,"沿原有全局用途；辅助对应待核验");}
        ref=lockPostingAuxiliary(code,currency.currencyId(),ref,p);
        return new Account(style,code,currency.currencyId(),ref,request.originalCurrencyId(),null,0,true,true,"原有全局用途及已明确财务代码/辅助对应");
    }
    private FinancialAuxiliaryValidationPort.Ref auxiliary(String code,UUID currency,UUID selected,Party party){
        if(selected==null&&party!=null){
            try{auxiliaries.inspect(new FinancialAuxiliaryValidationPort.Selection(code,null,currency));return null;}
            catch(ApiException required){/* The directory alone decides whether this account requires an auxiliary. */}
        }
        var ref=selected==null?(party==null?auxiliaries.inspect(new FinancialAuxiliaryValidationPort.Selection(code,null,currency)):auxiliaries.resolveNative(code,party.role(),party.id(),currency)):
                auxiliaries.validateForPosting(List.of(new FinancialAuxiliaryValidationPort.Selection(code,selected,currency))).getFirst();
        if(ref!=null&&(party==null||!Objects.equals(ref.role(),party.role())||!Objects.equals(ref.partyId(),party.id())))throw conflict("辅助项目与真实业务往来身份不符");return ref;
    }
    private FinancialAuxiliaryValidationPort.Ref postingAuxiliary(String role,String code,UUID currency,UUID selected,Party party){
        var ref=auxiliary(code,currency,selected,party);
        if(ref==null&&Set.of("AR_CONTROL","AP_CONTROL","CUSTOMER_ADVANCE","SUPPLIER_PREPAYMENT_ASSET","PROCUREMENT_GRNI_PENDING","PROCUREMENT_RETURN_PENDING_ASSET").contains(role)){
            if(party==null)throw conflict("该往来用途须明确真实辅助对象");ref=auxiliaries.resolveNative(code,party.role(),party.id(),currency);
            if(ref==null)throw conflict("该往来用途须对应财务辅助项目");
        }return ref;
    }
    private FinancialAuxiliaryValidationPort.Ref lockPostingAuxiliary(String code,UUID currency,FinancialAuxiliaryValidationPort.Ref ref,Party party){
        if(ref==null)return null;
        var locked=auxiliaries.validateForPosting(List.of(new FinancialAuxiliaryValidationPort.Selection(code,ref.auxiliaryId(),currency))).getFirst();
        if(locked==null||party==null||!Objects.equals(locked.role(),party.role())||!Objects.equals(locked.partyId(),party.id()))throw conflict("辅助对应在审核时已变化，请刷新核对原业务对象");
        return locked;
    }

    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void captureArAp(UUID ledgerId){
        if(!db.queryForList("SELECT ledger_id FROM finance_native_debt_accounts WHERE ledger_id=?",ledgerId).isEmpty())return;
        var r=db.queryForMap("SELECT * FROM ar_ap_ledger WHERE id=? AND legacy_id IS NULL AND status=1 AND NOT is_deleted",ledgerId);
        String direction=text(r,"direction"),source=text(r,"source_doc_type");
        // Prepayments and specialised supplier claims own different assets and must not masquerade as trade debt.
        if(!Set.of("SALES_SHIPMENT","SALES_RETURN","PURCHASE_RECEIPT","PURCHASE_RETURN","SUBCONTRACT_RECEIPT","SUBCONTRACT_RETURN","SUBCONTRACT_WASTE","PURCHASE_IQC_CREDIT","SUBCONTRACT_IQC_CREDIT").contains(source))return;
        Party party=new Party("AR".equals(direction)?"CUSTOMER":"SUPPLIER",(UUID)r.get("AR".equals(direction)?"client_id":"supplier_id"));
        LocalDate day=date(r.get("bill_date"));UUID originalCurrency=(UUID)r.get("currency_id");
        requireNoImportedPeriod(day);
        Account account=resolve(new Request("AR".equals(direction)?"AR_CONTROL":"AP_CONTROL",null,originalCurrency,party,day));
        if(account.styleId()==null)return; // Preserve the existing pre-accounting native lifecycle; first real GL remains explicit.
        Account counterpart=resolve(new Request("AR".equals(direction)?"SALES_REVENUE":"INVENTORY_ASSET",null,originalCurrency,party,day));
        String fp=sourceFingerprint(r);db.update("INSERT INTO finance_native_debt_accounts(ledger_id,account_snapshot,counterpart_snapshot,source_fingerprint,evidence_kind,created_by)VALUES(?,?::jsonb,?::jsonb,?,'NATIVE_APPROVAL',?)",ledgerId,encode(account),encode(counterpart),fp,current.requireId());
    }
    @Override @Transactional(propagation=Propagation.MANDATORY,readOnly=true)
    public Account frozenArAp(UUID ledgerId){var legacy=legacyBinding(ledgerId);if(legacy!=null)return legacy.account();var rows=db.queryForList("SELECT account_snapshot::text FROM finance_native_debt_correspondence_reviews WHERE ledger_id=? AND status='APPROVED' UNION ALL SELECT account_snapshot::text FROM finance_native_debt_accounts WHERE ledger_id=?",String.class,ledgerId,ledgerId);return rows.isEmpty()?null:decode(rows.getFirst(),Account.class);}
    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void captureStatementCredit(UUID ledgerId,UUID targetLedgerId){
        var credit=db.queryForMap("SELECT * FROM ar_ap_ledger WHERE id=? AND source_doc_type='PAYABLE_STATEMENT_CREDIT' AND direction='AP' AND status=1 AND NOT is_deleted",ledgerId);
        var target=db.queryForMap("SELECT * FROM ar_ap_ledger WHERE id=? AND direction='AP' AND status=1 AND NOT is_deleted",targetLedgerId);
        Account account=frozenArAp(targetLedgerId);
        if(account==null||!account.complete()||account.auxiliary()==null||!Objects.equals(credit.get("supplier_id"),target.get("supplier_id"))
            ||!Objects.equals(credit.get("currency_id"),target.get("currency_id"))||!Objects.equals(account.originalCurrencyId(),credit.get("currency_id"))
            ||db.queryForObject("SELECT count(*) FROM finance_payable_statement_adjustment_lines WHERE id=? AND target_ledger_id=? AND decision='RELEASED'",Integer.class,credit.get("source_doc_id"),targetLedgerId)!=1)
            throw conflict("本次减免必须保留原受审应付科目、真实供应商及原币身份");
        db.update("INSERT INTO finance_native_debt_accounts(ledger_id,account_snapshot,source_fingerprint,evidence_kind,created_by)VALUES(?,?::jsonb,?,'NATIVE_APPROVAL',?)",ledgerId,encode(account),sourceFingerprint(credit),current.requireId());
    }
    private NativeLegacyOpeningReadPort.Binding legacyBinding(UUID ledgerId){var reader=legacyOpenings==null?null:legacyOpenings.getIfAvailable();return reader==null?null:reader.read(ledgerId);}
    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void lockDebtSources(List<UUID> ledgerIds){
        lockDebtSources(ledgerIds,List.of());
    }
    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void lockDebtSources(List<UUID> ledgerIds,List<UUID> additionalStyleIds){
        com.uten.imp.application.concurrency.PaymentStyleHierarchyLock.lock(em);
        if(ledgerIds==null||ledgerIds.size()>2000||additionalStyleIds==null||additionalStyleIds.size()>2000)throw invalid("往来来源范围过大");var styles=new TreeSet<UUID>();
        additionalStyleIds.stream().filter(Objects::nonNull).forEach(styles::add);
        for(UUID id:ledgerIds.stream().filter(Objects::nonNull).distinct().sorted().toList()){var account=accountForSettlement(id);if(account!=null&&account.styleId()!=null)styles.add(account.styleId());}
        for(UUID style:styles)db.query("SELECT fn_finance_gl_settlement_lock_style(?,true)",rs->{},style);
    }
    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void lockCashSources(String kind,UUID id){
        if(!Set.of("PAYMENT","RECEIPT").contains(kind))throw invalid("收付款来源类别不正确");boolean payment="PAYMENT".equals(kind);
        var ids=db.queryForList("SELECT applied_ledger_id FROM "+(payment?"finance_payment_lines WHERE payment_id":"finance_receipt_lines WHERE receipt_id")+"=? AND NOT is_deleted",UUID.class,id);
        lockDebtSources(ids);
    }

    /** Original cash authority has already locked and calculated its real source lines. Freeze identities only. */
    @Transactional(propagation=Propagation.MANDATORY)
    public UUID prepareCash(String kind,UUID id){
        if(!Set.of("PAYMENT","RECEIPT").contains(kind))throw invalid("原生收付款类别不正确");
        boolean payment="PAYMENT".equals(kind);String table=payment?"finance_payments":"finance_receipts",lineTable=payment?"finance_payment_lines":"finance_receipt_lines",fk=payment?"payment_id":"receipt_id";
        var cash=db.queryForMap("SELECT * FROM "+table+" WHERE id=?",id);requireNoImportedPeriod(date(cash.get("bill_date")));
        var lines=db.queryForList("SELECT * FROM "+lineTable+" WHERE "+fk+"=? AND NOT is_deleted ORDER BY line_no,id",id);
        if(lines.isEmpty()){
            String role=payment?"SUPPLIER_PREPAYMENT_ASSET":"CUSTOMER_ADVANCE";Party party=new Party(payment?"SUPPLIER":"CUSTOMER",(UUID)cash.get(payment?"supplier_id":"client_id"));
            var account=resolve(new Request(role,null,(UUID)cash.get("currency_id"),party,date(cash.get("bill_date"))));
            db.update("INSERT INTO finance_native_cash_accounts(kind,cash_id,account_snapshot,created_by)VALUES(?,?,?::jsonb,?)",kind,id,encode(account),current.requireId());return account.styleId();
        }
        UUID first=null;int ordinal=0;
        for(var line:lines){
            UUID ledger=(UUID)line.get("applied_ledger_id");Account account=accountForSettlement(ledger);
            if(account==null||account.styleId()==null)throw conflict("原往来缺少可定位的已记账科目，请先核对或生成原来源凭证，不能按当前科目用途猜配");
            if(!Objects.equals(account.originalCurrencyId(),cash.get("currency_id")))throw conflict("原债务的真实原币单位与本次收付款不一致");
            bindExistingArApEntry(ledger);
            if(first==null)first=account.styleId();ordinal++;
            var source=db.queryForMap("SELECT * FROM ar_ap_ledger WHERE id=?",ledger);
            var legacy=legacyBinding(ledger);
            if(!Objects.equals(source.get(payment?"supplier_id":"client_id"),cash.get(payment?"supplier_id":"client_id")))throw conflict("原往来对象与收付款不一致");
            db.update("""
                INSERT INTO finance_native_cash_debt_parts(kind,cash_id,source_line_id,ledger_id,line_no,account_snapshot,
                  amount_original,amount_local,source_fingerprint,created_by,legacy_opening_review_id)VALUES(?,?,?,?,?,?::jsonb,?,?,?,?,?)
                """,kind,id,line.get("id"),ledger,ordinal,encode(account),line.get("amount_original"),line.get("applied_amount_local"),sourceFingerprint(source),current.requireId(),legacy==null?null:legacy.reviewId());
            db.update("INSERT INTO finance_native_cash_debt_entry_links(kind,cash_id,source_line_id,entry_id)SELECT ?,?,?,entry_id FROM finance_native_debt_entry_refs WHERE ledger_id=?",kind,id,line.get("id"),ledger);
        }return first;
    }
    private Account existingBookedAccount(UUID ledgerId){
        var ledgers=db.queryForList("SELECT * FROM ar_ap_ledger WHERE id=?",ledgerId);if(ledgers.size()!=1)return null;var l=ledgers.getFirst();
        var entries=db.queryForList("""
            SELECT e.id,e.style_id,a.* FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id
            LEFT JOIN finance_gl_entry_allocations a ON a.entry_id=e.id
            WHERE NOT e.is_deleted AND v.status=1 AND NOT v.is_deleted AND v.reversed_by_voucher_id IS NULL
              AND v.source_type=CASE ?::text WHEN 'AR' THEN 'AR_POST' ELSE 'AP_POST' END AND v.source_doc_id=?
              AND v.period=to_char(?::date,'YYYY-MM') AND e.line_no=CASE ?::text WHEN 'AR' THEN 1 ELSE 2 END
              AND e.amount=? ORDER BY e.id,a.allocation_no
            """,l.get("direction"),l.get("source_doc_id"),l.get("bill_date"),l.get("direction"),l.get("amount_original_local"));
        if(entries.size()!=1)return null;var e=entries.getFirst();
        FinancialAuxiliaryValidationPort.Ref ref=e.get("auxiliary_id")==null?null:new FinancialAuxiliaryValidationPort.Ref((UUID)e.get("auxiliary_id"),text(e,"auxiliary_role"),(UUID)e.get("party_id_snapshot"),text(e,"source_system"),text(e,"source_code"),text(e,"source_name"));
        boolean complete=e.get("account_code")!=null&&e.get("currency_id")!=null&&Objects.equals(e.get("original_currency_id"),l.get("currency_id"))
            &&e.get("amount_original")!=null&&amount(e,"amount_original").compareTo(amount(l,"amount_original"))==0;
        return new Account((UUID)e.get("style_id"),text(e,"account_code"),(UUID)e.get("currency_id"),ref,(UUID)l.get("currency_id"),null,0,true,complete,
                complete?"直接读取原已记账分录及辅助/原币证据":"直接读取原已记账科目；历史分录缺少财务代码/辅助证据，不重标历史");
    }
    private Account accountForSettlement(UUID ledgerId){
        Account account=frozenArAp(ledgerId);if(account==null)account=existingBookedAccount(ledgerId);if(account!=null)return account;
        // Keep the already-supported verified bootstrap workflow before a real R1 accounting baseline is activated.
        // This is the current cash document's old business posting role, explicitly not a historical debt-account proof.
        if(Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM finance_gl_opening_baselines b JOIN finance_accounting_import_batches batch ON batch.id=b.import_batch_id WHERE batch.status='POSTED' AND batch.reversed_at IS NULL)",Boolean.class)))return null;
        var rows=db.queryForList("SELECT direction,currency_id,fn_is_verified_legacy_opening_target(id,direction) AS verified FROM ar_ap_ledger WHERE id=?",ledgerId);
        if(rows.size()!=1||!Boolean.TRUE.equals(rows.getFirst().get("verified")))return null;var ledger=rows.getFirst();
        UUID style=db.queryForObject("SELECT system_posting_style_id(?)",UUID.class,"AR".equals(ledger.get("direction"))?"AR_CONTROL":"AP_CONTROL");
        return style==null?null:new Account(style,null,null,null,(UUID)ledger.get("currency_id"),null,0,true,false,"尚未启用原账套期初接续；沿已核旧目标的原业务默认用途记录本次收付款，原立账科目及期初仍待对应");
    }
    private void bindExistingArApEntry(UUID ledgerId){
        if(!db.queryForList("SELECT ledger_id FROM finance_native_debt_entry_refs WHERE ledger_id=?",ledgerId).isEmpty())return;
        var rows=db.queryForList("""
            SELECT e.voucher_id,e.line_no,v.source_type FROM ar_ap_ledger l JOIN gl_vouchers v ON v.source_type=CASE l.direction WHEN 'AR' THEN 'AR_POST' ELSE 'AP_POST' END
             AND v.source_doc_id=l.source_doc_id AND v.period=to_char(l.bill_date,'YYYY-MM') AND v.status=1 AND NOT v.is_deleted AND v.reversed_by_voucher_id IS NULL
            JOIN gl_entries e ON e.voucher_id=v.id AND e.line_no=CASE l.direction WHEN 'AR' THEN 1 ELSE 2 END AND NOT e.is_deleted
            WHERE l.id=?
            """,ledgerId);
        if(rows.size()==1)bindArApEntry(ledgerId,(UUID)rows.getFirst().get("voucher_id"),((Number)rows.getFirst().get("line_no")).intValue(),false);
    }
    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void bindArApEntry(UUID ledgerId,UUID voucherId,int entryLine,boolean ownerReversesJournal){
        var rows=db.queryForList("""
            SELECT e.id,e.style_id,e.direction,e.amount,v.source_type,l.direction ledger_direction,l.amount_original_local,l.source_doc_id
            FROM ar_ap_ledger l JOIN gl_vouchers v ON v.id=? AND v.status=1 AND NOT v.is_deleted AND v.reversed_by_voucher_id IS NULL
            JOIN gl_entries e ON e.voucher_id=v.id AND e.line_no=? AND NOT e.is_deleted WHERE l.id=?
              AND ((? AND e.source_doc_type IN('PROCUREMENT_AP_RECOGNITION_LINE','PAYABLE_STATEMENT_CREDIT_LINE') AND e.source_doc_id=l.id
                  AND (e.source_doc_type='PROCUREMENT_AP_RECOGNITION_LINE' OR (v.source_type='PAYABLE_STATEMENT_CREDIT' AND l.source_doc_type='PAYABLE_STATEMENT_CREDIT')))
                OR (NOT ? AND v.source_type=CASE l.direction WHEN 'AR' THEN 'AR_POST' ELSE 'AP_POST' END AND v.source_doc_id=l.source_doc_id))
            """,voucherId,entryLine,ledgerId,ownerReversesJournal,ownerReversesJournal);
        if(rows.size()!=1)throw conflict("原债务缺少唯一可冻结的真实分录");var row=rows.getFirst();int natural="AR".equals(row.get("ledger_direction"))?1:-1;
        if(amount(row,"amount").multiply(BigDecimal.valueOf(((Number)row.get("direction")).intValue())).compareTo(amount(row,"amount_original_local").multiply(BigDecimal.valueOf(natural)))!=0)throw conflict("原债务分录与已确认账面额不一致，不能冻结或生成第二套债务");
        Account frozen=frozenArAp(ledgerId);if(frozen!=null&&!Objects.equals(frozen.styleId(),row.get("style_id")))throw conflict("原已记账科目与审核时冻结对应不一致");
        var previous=db.queryForList("SELECT entry_id FROM finance_native_debt_entry_refs WHERE ledger_id=?",ledgerId);
        if(!previous.isEmpty()){if(!Objects.equals(previous.getFirst().get("entry_id"),row.get("id")))throw conflict("原债务已经冻结其他真实分录，不能替换");return;}
        db.update("INSERT INTO finance_native_debt_entry_refs(ledger_id,entry_id,voucher_id,owner_reverses_journal,created_by)VALUES(?,?,?,?,?)",ledgerId,row.get("id"),voucherId,ownerReversesJournal,current.requireId());
    }
    @Override @Transactional(propagation=Propagation.MANDATORY)
    public boolean reverseArApGl(UUID ledgerId){
        var rows=db.queryForList("SELECT * FROM finance_native_debt_entry_refs WHERE ledger_id=?",ledgerId);if(rows.isEmpty())return false;
        var row=rows.getFirst();if(Boolean.TRUE.equals(row.get("owner_reverses_journal")))return false;
        controlledJournals.getObject().reverse((UUID)row.get("voucher_id"),"NATIVE-ARAP-REV-"+ledgerId,com.uten.imp.common.time.BusinessTime.today(),"NATIVE_ARAP_REV",ledgerId,"NATIVE_ARAP_REV","原生往来反审，保留原债务分录及冻结引用",current.requireId());return true;
    }
    @Transactional(propagation=Propagation.MANDATORY)
    public void attachCash(String kind,UUID id){
        db.queryForObject("SELECT fn_finance_attach_native_cash_allocations(?,?)",Integer.class,kind,id);
    }
    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void supplierOffsetApplied(UUID allocationId){
        var offset=db.queryForMap("SELECT * FROM supplier_open_item_offsets WHERE id=? AND status='APPLIED'",allocationId);
        if(offset.get("resolution_id")!=null)return; // Dedicated supplier claims retain their original receivable/loss journal authority.
        if(!db.queryForList("SELECT offset_id FROM finance_native_supplier_offset_journals WHERE offset_id=?",allocationId).isEmpty())return;
        UUID sourceId=(UUID)offset.get("source_ledger_id"),targetId=(UUID)offset.get("target_ledger_id");
        Account source=accountForSettlement(sourceId);Account target=accountForSettlement(targetId);
        if(source==null||target==null)throw conflict("抵销来源缺少原科目身份，请先核对原往来分录；不能按当前用途替代原债务");
        bindExistingArApEntry(sourceId);bindExistingArApEntry(targetId);
        BigDecimal sourceLocal=amount(offset,"source_amount_local"),targetLocal=amount(offset,"target_amount_local");
        if(sourceLocal.compareTo(targetLocal)!=0)throw conflict("供应商抵销原账面额不守恒，须走明确汇差处理");
        LocalDate effective=date(offset.get("effective_date"));requireNoImportedPeriod(effective);UUID voucher=null;
        boolean same=Objects.equals(source.styleId(),target.styleId())&&Objects.equals(source.accountCode(),target.accountCode())
                &&Objects.equals(source.accountingCurrencyId(),target.accountingCurrencyId())
                &&Objects.equals(source.auxiliary()==null?null:source.auxiliary().auxiliaryId(),target.auxiliary()==null?null:target.auxiliary().auxiliaryId());
        if(!same&&sourceLocal.signum()!=0){
            BigDecimal original=amount(offset,"amount_original");
            var entries=List.of(new FinanceControlledJournalService.Entry(target.styleId(),1,targetLocal,"按原应付科目应用供应商贷项",allocation(target,original,allocationId)),
                    new FinanceControlledJournalService.Entry(source.styleId(),-1,sourceLocal,"按原贷项科目释放供应商贷项",allocation(source,original,allocationId)));
            voucher=controlledJournals.getObject().post("NATIVE-OFFSET-"+allocationId,effective,"NATIVE_SUPPLIER_OFFSET",allocationId,"NATIVE_SUPPLIER_OFFSET","原生抵销按冻结科目/辅助转账，无新现金或库存",entries,current.requireId()).voucherId();
        }
        db.update("INSERT INTO finance_native_supplier_offset_journals(offset_id,source_account,target_account,voucher_id,created_by)VALUES(?,?::jsonb,?::jsonb,?,?)",allocationId,encode(source),encode(target),voucher,current.requireId());
    }
    private FinanceControlledJournalService.Allocation allocation(Account a,BigDecimal original,UUID source){return !a.complete()?null:new FinanceControlledJournalService.Allocation(a.accountCode(),a.accountingCurrencyId(),a.auxiliary(),source.toString(),1,encode(a),a.originalCurrencyId(),original,null);}
    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void supplierOffsetReversed(UUID allocationId,String reason){
        var rows=db.queryForList("SELECT * FROM finance_native_supplier_offset_journals WHERE offset_id=? FOR UPDATE",allocationId);if(rows.isEmpty())return;
        var row=rows.getFirst();if(row.get("reversed_at")!=null)return;UUID reversal=null;
        if(row.get("voucher_id")!=null)reversal=controlledJournals.getObject().reverse((UUID)row.get("voucher_id"),"NATIVE-OFFSET-REV-"+allocationId,com.uten.imp.common.time.BusinessTime.today(),"NATIVE_SUPPLIER_OFFSET_REV",allocationId,"NATIVE_SUPPLIER_OFFSET_REV",reason,current.requireId()).voucherId();
        db.update("UPDATE finance_native_supplier_offset_journals SET reversal_voucher_id=?,reversed_at=now() WHERE offset_id=? AND reversed_at IS NULL",reversal,allocationId);
    }
    @Override @Transactional(propagation=Propagation.MANDATORY)
    public void captureCustomerOffset(UUID allocationId){
        if(!db.queryForList("SELECT offset_id FROM finance_native_customer_offset_accounts WHERE offset_id=?",allocationId).isEmpty())return;
        var offset=db.queryForMap("SELECT * FROM customer_open_item_offsets WHERE id=? AND status='APPLIED'",allocationId);
        var source=db.queryForMap("SELECT * FROM ar_ap_ledger WHERE id=?",offset.get("source_ledger_id"));UUID receipt=(UUID)source.get("source_doc_id");
        var cash=db.queryForList("SELECT account_snapshot::text FROM finance_native_cash_accounts WHERE kind='RECEIPT' AND cash_id=?",String.class,receipt);
        Account advance;
        if(!cash.isEmpty())advance=decode(cash.getFirst(),Account.class);
        else{
            var rows=db.queryForList("SELECT gl_counter_style_id FROM finance_receipts WHERE id=? AND settlement_authority_version>=1 AND NOT is_deleted AND status=1",receipt);
            if(rows.size()!=1||rows.getFirst().get("gl_counter_style_id")==null)throw conflict("客户预收缺少原已审核科目快照，请先受审核对原收款");
            advance=new Account((UUID)rows.getFirst().get("gl_counter_style_id"),null,null,null,(UUID)source.get("currency_id"),null,0,true,false,"直接读取原收款冻结预收科目；历史财务代码及辅助证据待核");
        }
        UUID targetId=(UUID)offset.get("target_ledger_id");Account target=accountForSettlement(targetId);
        if(target==null)throw conflict("正式应收缺少原科目身份，请先核对原应收分录，不按当前用途重标");
        bindExistingArApEntry(targetId);
        if(!Objects.equals(advance.originalCurrencyId(),offset.get("currency_id"))||!Objects.equals(target.originalCurrencyId(),offset.get("currency_id")))throw conflict("预收转销的真实原币单位与原来源不符");
        requireNoImportedPeriod(date(offset.get("effective_date")));
        db.update("INSERT INTO finance_native_customer_offset_accounts(offset_id,source_account,target_account,created_by)VALUES(?,?::jsonb,?::jsonb,?)",allocationId,encode(advance),encode(target),current.requireId());
    }

    /** Import approval owns an original complete month. Native generation must never silently book it a second time. */
    @Transactional(propagation=Propagation.MANDATORY,readOnly=true)
    public void requireNoImportedPeriod(LocalDate day){
        if(Boolean.TRUE.equals(db.queryForObject("""
            SELECT EXISTS(SELECT 1 FROM finance_accounting_period_coverage c JOIN finance_accounting_import_batches b ON b.id=c.import_batch_id
              WHERE b.status='POSTED' AND b.reversed_at IS NULL AND c.source_kind='ORIGINAL_BALANCE_AND_COMPLETE_JOURNALS'
                AND c.period=to_char(?::date,'YYYY-MM'))
            """,Boolean.class,day)))throw conflict("该月份已按原账套完整凭证接续，不能重新生成或重复立原生往来；请使用未接续的新业务期间或走受审更正");
    }

    @Override @Transactional(propagation=Propagation.MANDATORY,readOnly=true)
    public Map<UUID,Debt> readArAp(List<UUID> ids){
        if(ids==null||ids.size()>2000)throw invalid("一次最多读取2000个真实往来来源");Map<UUID,Debt> result=new LinkedHashMap<>();
        for(UUID id:ids.stream().filter(Objects::nonNull).distinct().sorted().toList()){
            var rows=db.queryForList("SELECT * FROM ar_ap_ledger WHERE id=?",id);if(rows.isEmpty())continue;var r=rows.getFirst();Account a=frozenArAp(id);if(a==null)a=existingBookedAccount(id);
            String direction=text(r,"direction");Party party=new Party("AR".equals(direction)?"CUSTOMER":"SUPPLIER",(UUID)r.get("AR".equals(direction)?"client_id":"supplier_id"));
            var legacy=legacyBinding(id);
            if(legacy!=null){result.put(id,new Debt(id,direction,party,(UUID)r.get("currency_id"),date(r.get("bill_date")),amount(r,"amount_original"),amount(r,"amount_original_local"),amount(r,"amount_balance_original"),amount(r,"amount_balance"),legacy.sources(),true,legacy.account().basis(),legacy.fingerprint()));continue;}
            List<FinancialFrozenDebtReadPort.Entry> entries=new ArrayList<>();boolean complete=a!=null&&a.complete();
            if(a!=null){var booked=db.queryForList("""
                SELECT e.id,e.voucher_id,e.direction,e.amount,a.allocation_no,a.amount_original allocation_original,a.original_currency_id allocation_original_currency FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id
                LEFT JOIN finance_gl_entry_allocations a ON a.entry_id=e.id
                WHERE NOT e.is_deleted AND fn_finance_gl_voucher_is_booked(v.id) AND v.reversal_of_voucher_id IS NULL
                  AND (NOT EXISTS(SELECT 1 FROM finance_native_debt_entry_refs frozen WHERE frozen.ledger_id=?)
                    OR EXISTS(SELECT 1 FROM finance_native_debt_entry_refs frozen WHERE frozen.ledger_id=? AND frozen.entry_id=e.id))
                  AND e.style_id=? AND ((v.source_type IN('AR_POST','AP_POST') AND v.source_doc_id=? AND v.period=to_char(?::date,'YYYY-MM'))
                    OR (e.source_doc_type IN('PROCUREMENT_AP_RECOGNITION_LINE','PAYABLE_STATEMENT_CREDIT_LINE') AND e.source_doc_id=?)) ORDER BY e.id,a.allocation_no
                """,id,id,a.styleId(),r.get("source_doc_id"),r.get("bill_date"),id);
                for(var e:booked){entries.add(new FinancialFrozenDebtReadPort.Entry("BOOKED_GL",(UUID)e.get("voucher_id"),(UUID)e.get("id"),(Integer)e.get("allocation_no"),a.styleId(),a.accountCode(),a.accountingCurrencyId(),a.auxiliary(),(UUID)e.get("allocation_original_currency"),(BigDecimal)e.get("allocation_original"),amount(e,"amount"),((Number)e.get("direction")).intValue(),sourceFingerprint(r)));if(e.get("allocation_no")==null)complete=false;}
                // Zero book amounts are real original-currency debts with an identity snapshot, not fictitious zero GL entries.
                if(entries.isEmpty()&&amount(r,"amount_original_local").signum()==0)entries.add(new FinancialFrozenDebtReadPort.Entry("ZERO_BOOK_SOURCE",null,null,null,a.styleId(),a.accountCode(),a.accountingCurrencyId(),a.auxiliary(),a.originalCurrencyId(),amount(r,"amount_original"),BigDecimal.ZERO,"AR".equals(direction)?1:-1,sourceFingerprint(r)));
                if(entries.isEmpty())complete=false;
            }
            result.put(id,new Debt(id,direction,party,(UUID)r.get("currency_id"),date(r.get("bill_date")),amount(r,"amount_original"),amount(r,"amount_original_local"),amount(r,"amount_balance_original"),amount(r,"amount_balance"),List.copyOf(entries),complete,a==null?"旧来源缺少原科目快照，须核对原分录；不按当前用途重标":a.basis(),sourceFingerprint(r)));
        }return Collections.unmodifiableMap(result);
    }
    private String sourceFingerprint(Map<String,Object> r){Map<String,Object> stable=new LinkedHashMap<>();for(String k:List.of("id","direction","source_doc_type","source_doc_id","bill_date","client_id","supplier_id","currency_id","amount_original","amount_original_local","exchange_rate"))stable.put(k,r.get(k));return hash(encode(stable));}
    private String encode(Object value){try{return json.writeValueAsString(value);}catch(Exception e){throw invalid("会计对应资料无法保存");}}
    private <T>T decode(String value,Class<T> type){try{return json.readValue(value,type);}catch(Exception e){throw conflict("原会计对应快照无法读取，请保留原结果核对");}}
    private static String hash(String value){return ImmutableDocumentStore.digest(value.getBytes(java.nio.charset.StandardCharsets.UTF_8));}
    private static String text(Map<String,Object> r,String key){return Objects.toString(r.get(key),null);}
    private static BigDecimal amount(Map<String,Object> r,String key){return r.get(key)==null?BigDecimal.ZERO:(BigDecimal)r.get(key);}
    private static LocalDate date(Object v){return v instanceof java.sql.Date d?d.toLocalDate():(LocalDate)v;}
    private static ApiException invalid(String v){return new ApiException(ErrorCode.VALIDATION_FAILED,v);}
    private static ApiException conflict(String v){return new ApiException(ErrorCode.CONFLICT,v);}
    private void chartLock(){db.query("SELECT pg_advisory_xact_lock_shared(hashtextextended('uten:finance-chart',0))",rs->{});}
}
