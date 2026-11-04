package com.uten.imp.features.finance.gl;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.*;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.*;
import com.uten.imp.security.*;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;

/** A reviewed source relationship, not another balance, payment, AP or GL writer. */
@Service @RequiredArgsConstructor
public class NativeLegacyOpeningService implements NativeLegacyOpeningReadPort {
    private final JdbcTemplate db;private final ObjectMapper json;private final FinancialOpeningSourceReadPort openings;
    private final FinancialAuxiliaryValidationPort auxiliaries;private final SecurityContextCurrentUser current;
    private final FinanceDocumentAccessPolicy access;private final TxSessionVars tx;
    public record Share(UUID ledgerId,UUID entryId,int allocationNo,@com.fasterxml.jackson.annotation.JsonFormat(shape=com.fasterxml.jackson.annotation.JsonFormat.Shape.STRING)BigDecimal amountLocal,@com.fasterxml.jackson.annotation.JsonFormat(shape=com.fasterxml.jackson.annotation.JsonFormat.Shape.STRING)BigDecimal nativeOriginal) { }
    public record Submit(UUID requestId,String sourceReference,List<Share> shares) { }
    record Legacy(UUID ledgerId,UUID proofId,String role,UUID partyId,UUID currencyId,LocalDate cutoff,@com.fasterxml.jackson.annotation.JsonFormat(shape=com.fasterxml.jackson.annotation.JsonFormat.Shape.STRING)BigDecimal local,@com.fasterxml.jackson.annotation.JsonFormat(shape=com.fasterxml.jackson.annotation.JsonFormat.Shape.STRING)BigDecimal original,String fingerprint,String billNo) { }
    record Item(Share request,FinancialOpeningSourceReadPort.Source source,@com.fasterxml.jackson.annotation.JsonFormat(shape=com.fasterxml.jackson.annotation.JsonFormat.Shape.STRING)BigDecimal financialOriginal) { }
    record Target(Legacy legacy,NativeFinancialPostingAccountPort.Account account) { }
    record Plan(List<Target> targets,List<Item> items) { }
    private void readAccess(){CurrentAuthorityGuard.requireAll("finance_report:view","ar_ap_ledger:view");FinanceCompanyReportAccess.require(access);}
    private void writeAccess(){readAccess();CurrentAuthorityGuard.requireAll("payment_style:edit","finance_post:execute");}
    private void lock(){db.query("SELECT pg_advisory_xact_lock(hashtextextended('uten:native-legacy-opening',0))",rs->{});}

    @Transactional(readOnly=true)
    public Map<String,Object> preview(UUID ledgerId,int page,int size){
        readAccess();var active=read(ledgerId);if(active!=null)return Map.of("binding",active,"review",response(active.reviewId()));
        Legacy legacy=legacy(ledgerId,false);var result=new LinkedHashMap<String,Object>();result.put("legacy",legacy);
        result.put("sources",openings.choices(legacy.role(),legacy.partyId(),legacy.cutoff().plusDays(1),page,size));
        result.put("reviews",db.queryForList("SELECT r.id,r.status,r.source_reference,r.created_by,r.approved_by FROM finance_native_legacy_opening_reviews r WHERE EXISTS(SELECT 1 FROM finance_native_legacy_opening_targets t WHERE t.review_id=r.id AND t.ledger_id=?) OR EXISTS(SELECT 1 FROM jsonb_array_elements(r.plan->'targets') target WHERE target->'legacy'->>'ledgerId'=?::text) ORDER BY r.created_at DESC,r.id",ledgerId,ledgerId));return result;
    }
    @Transactional
    public Map<String,Object> submit(Submit input){
        writeAccess();if(input==null||input.requestId()==null||input.sourceReference()==null||input.sourceReference().isBlank()||input.sourceReference().length()>2000)throw invalid("请填写期初接续依据并保留提交编号");
        tx.bind();lock();String hash=hash(input);var old=db.queryForList("SELECT * FROM finance_native_legacy_opening_reviews WHERE request_id=?",input.requestId());
        if(!old.isEmpty()){if(!hash.equals(old.getFirst().get("payload_hash"))||!current.requireId().equals(old.getFirst().get("created_by")))throw conflict("该期初接续请求已使用，请保留原内容核对结果");return response((UUID)old.getFirst().get("id"));}
        Plan plan=plan(input.shares(),false);UUID id=UUID.randomUUID();
        db.update("INSERT INTO finance_native_legacy_opening_reviews(id,request_id,payload_hash,source_reference,plan,created_by)VALUES(?,?,?,?,?::jsonb,?)",id,input.requestId(),hash,input.sourceReference().strip(),encode(plan),current.requireId());return response(id);
    }
    @Transactional
    public Map<String,Object> approve(UUID id){
        writeAccess();tx.bind();lock();var review=review(id,true);if("APPROVED".equals(review.get("status")))return response(id);
        if(!"DRAFT".equals(review.get("status")))throw conflict("期初接续已经撤回，请保留原记录重新提交");
        if(current.requireId().equals(review.get("created_by")))throw conflict("期初接续须由另一名财务审核人核对两套来源");
        Plan stored=decode(review.get("plan").toString(),Plan.class);var requests=stored.items().stream().map(Item::request).toList();
        for(UUID style:stored.items().stream().map(i->i.source().styleId()).distinct().sorted().toList())db.query("SELECT fn_finance_gl_settlement_lock_style(?,true)",rs->{},style);
        Plan checked=plan(requests,true);if(!hash(stored).equals(hash(checked)))throw conflict("原期初或旧未结证据已变化，请退回核对后重新提交");
        Map<UUID,UUID> targetIds=new HashMap<>();
        for(var target:checked.targets()){
            var legacy=target.legacy();if(read(legacy.ledgerId())!=null)throw conflict("这个旧目标已有生效的期初接续，不能再次认领");UUID targetId=UUID.randomUUID();targetIds.put(legacy.ledgerId(),targetId);
            db.update("INSERT INTO finance_native_legacy_opening_targets(id,review_id,ledger_id,legacy_proof_id,legacy_fingerprint,cutoff_date,native_original_currency_id,account_snapshot)VALUES(?,?,?,?,?,?,?,?::jsonb)",targetId,id,legacy.ledgerId(),legacy.proofId(),legacy.fingerprint(),legacy.cutoff(),legacy.currencyId(),encode(target.account()));
        }
        for(var item:checked.items()){
            var source=item.source();var part=item.request();db.update("""
                INSERT INTO finance_native_legacy_opening_parts(id,review_id,target_id,ledger_id,entry_id,allocation_no,opening_evidence_id,
                  import_batch_id,balance_import_id,amount_local,amount_original,native_original,native_original_currency_id,source_fingerprint,source_snapshot)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?::jsonb)
                """,UUID.randomUUID(),id,targetIds.get(part.ledgerId()),part.ledgerId(),part.entryId(),part.allocationNo(),source.openingEvidenceId(),source.importBatchId(),source.balanceImportId(),part.amountLocal(),item.financialOriginal(),part.nativeOriginal(),checked.targets().stream().filter(t->t.legacy().ledgerId().equals(part.ledgerId())).findFirst().orElseThrow().legacy().currencyId(),source.fingerprint(),encode(source));
        }
        db.update("UPDATE finance_native_legacy_opening_reviews SET status='APPROVED',approved_by=?,approved_at=now() WHERE id=? AND status='DRAFT'",current.requireId(),id);return response(id);
    }
    @Transactional
    public Map<String,Object> withdraw(UUID id,String reason){
        writeAccess();if(reason==null||reason.isBlank()||reason.length()>2000)throw invalid("请填写撤回依据");tx.bind();lock();var review=review(id,true);
        if("REVERSED".equals(review.get("status")))return response(id);if(!"APPROVED".equals(review.get("status")))throw conflict("只能撤回已审核的期初接续");
        var targets=db.queryForList("SELECT ledger_id,account_snapshot FROM finance_native_legacy_opening_targets WHERE review_id=? ORDER BY ledger_id",id);
        for(var t:targets){var account=decode(t.get("account_snapshot").toString(),NativeFinancialPostingAccountPort.Account.class);db.query("SELECT fn_finance_gl_settlement_lock_style(?,true)",rs->{},account.styleId());legacy((UUID)t.get("ledger_id"),true);}
        db.update("UPDATE finance_native_legacy_opening_reviews SET status='REVERSED',reversed_by=?,reversed_at=now(),reverse_reason=? WHERE id=? AND status='APPROVED'",current.requireId(),reason.strip(),id);return response(id);
    }
    @Transactional(readOnly=true)
    public Map<String,Object> operation(UUID requestId){
        readAccess();var rows=db.queryForList("SELECT id FROM finance_native_legacy_opening_reviews WHERE request_id=? AND created_by=?",requestId,current.requireId());
        if(rows.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"本人原接续请求尚无成功回执；未找到不表示未写，请保留原请求");
        var result=response((UUID)rows.getFirst().get("id"));result.put("receiptActorId",current.requireId());result.put("receiptRequestId",requestId);return result;
    }
    @Transactional(readOnly=true)
    public Map<String,Object> actionReceipt(UUID id,String action){
        readAccess();if(!Set.of("approve","withdraw").contains(action))throw invalid("请选择原审核或撤回操作");
        var rows=db.queryForList("SELECT id FROM finance_native_legacy_opening_reviews WHERE id=? AND "+(action.equals("approve")?"approved_by=? AND approved_at IS NOT NULL":"reversed_by=? AND reversed_at IS NOT NULL"),id,current.requireId());
        if(rows.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"本人原接续操作尚无成功回执；请保留原操作核对");
        var result=response(id);result.put("receiptActorId",current.requireId());result.put("receiptAction",action);return result;
    }
    @Transactional(readOnly=true)
    public Map<String,Object> response(UUID id){readAccess();var r=new LinkedHashMap<>(review(id,false));r.remove("payload_hash");r.put("plan",decode(r.get("plan").toString(),Map.class));var parts=db.queryForList("SELECT id,ledger_id,entry_id,allocation_no,amount_local,amount_original,native_original,native_original_currency_id,source_fingerprint FROM finance_native_legacy_opening_parts WHERE review_id=? ORDER BY ledger_id,entry_id,allocation_no",id);parts.forEach(com.uten.imp.common.report.ReportQueryKit::includeDecimalTexts);r.put("parts",parts);return r;}

    private Plan plan(List<Share> shares,boolean locked){
        if(shares==null||shares.isEmpty()||shares.size()>2000||shares.stream().anyMatch(Objects::isNull))throw invalid("请明确选择1至2000份原期初分配与旧未结关系");
        var ordered=shares.stream().sorted(Comparator.comparing(Share::ledgerId,Comparator.nullsFirst(Comparator.naturalOrder())).thenComparing(Share::entryId,Comparator.nullsFirst(Comparator.naturalOrder())).thenComparingInt(Share::allocationNo)).toList();
        var refs=new ArrayList<FinanceGlSettlementCapacityPort.SourceRef>();var keys=new HashSet<String>();var legacyMap=new LinkedHashMap<UUID,Legacy>();
        for(var part:ordered){if(part.ledgerId()==null||part.entryId()==null||part.allocationNo()<1||part.amountLocal()==null||part.nativeOriginal()==null||part.amountLocal().signum()<0||part.nativeOriginal().signum()<0||part.amountLocal().signum()+part.nativeOriginal().signum()==0)throw invalid("期初关系须包含真实分录、旧目标及非负的明确份额");FinancialExactAmount.book(part.amountLocal(),"接续本币份额");FinancialExactAmount.require(part.nativeOriginal(),"旧未结原币份额");
            if(!keys.add(part.ledgerId()+"|"+part.entryId()+"|"+part.allocationNo()))throw invalid("同一旧目标与原分配不能重复");legacyMap.computeIfAbsent(part.ledgerId(),ledger->legacy(ledger,locked));refs.add(new FinanceGlSettlementCapacityPort.SourceRef(part.entryId(),part.allocationNo()));}
        var sources=openings.read(refs);var items=new ArrayList<Item>();var accounts=new LinkedHashMap<UUID,NativeFinancialPostingAccountPort.Account>();
        for(var part:ordered){var legacy=legacyMap.get(part.ledgerId());var source=sources.get(new FinanceGlSettlementCapacityPort.SourceRef(part.entryId(),part.allocationNo()));if(source==null)throw conflict("请选择仍有效的原账套期初分录及辅助明细，不能用普通发生额或已反向来源代替");
            int natural="CUSTOMER".equals(legacy.role())?1:-1;
            if(!source.effectiveFrom().equals(legacy.cutoff().plusDays(1))||source.direction()!=natural||source.amountLocal().signum()<0||source.auxiliary()==null||!Objects.equals(source.auxiliary().role(),legacy.role())||!Objects.equals(source.auxiliary().partyId(),legacy.partyId()))throw invalid("原期初截止日、借贷方向或真实往来对象与已核旧未结不一致");
            if(source.originalCurrencyId()!=null&&!source.originalCurrencyId().equals(legacy.currencyId()))throw invalid("原金融来源的真实原币单位与旧已核原币不同，不能强并");
            var ref=auxiliaries.inspectHistorical(new FinancialAuxiliaryValidationPort.Selection(source.accountCode(),source.auxiliary().auxiliaryId(),source.accountingCurrencyId()));if(ref==null||!Objects.equals(ref.partyId(),legacy.partyId())||!Objects.equals(ref.role(),legacy.role()))throw conflict("原辅助身份已变化，请先核对真实来源");
            var account=new NativeFinancialPostingAccountPort.Account(source.styleId(),source.accountCode(),source.accountingCurrencyId(),source.auxiliary(),legacy.currencyId(),null,0,false,true,"已双源核对的旧未结期初；本币来自原账套期初，原币按旧受验来源单列，不补未知金融原币");
            var previous=accounts.putIfAbsent(legacy.ledgerId(),account);if(previous!=null&&!sameScope(previous,account))throw invalid("一个旧未结目标须明确对应同一核算科目、辅助及币别范围；不能把跨账户来源自动混成一笔清偿");
            items.add(new Item(part,source,source.amountOriginal()==null?null:part.nativeOriginal()));
        }
        for(var legacy:legacyMap.values()){
            var rows=items.stream().filter(i->i.request().ledgerId().equals(legacy.ledgerId())).toList();equal(sum(rows,true),legacy.local(),"旧初始未结本币");equal(sum(rows,false),legacy.original(),"旧初始未结原币");}
        for(var reference:refs.stream().distinct().toList()){
            var source=sources.get(reference);var rows=items.stream().filter(i->i.source().reference().equals(reference)).toList();
            var used=db.queryForMap("SELECT COALESCE(sum(p.amount_local),0) local,COALESCE(sum(p.amount_original),0) original FROM finance_native_legacy_opening_parts p JOIN finance_native_legacy_opening_reviews r ON r.id=p.review_id AND r.status='APPROVED' WHERE p.entry_id=? AND p.allocation_no=?",reference.entryId(),reference.allocationNo());
            var publicClaims=db.queryForMap("SELECT COALESCE(sum(p.amount_local),0) local,COALESCE(sum(p.amount_original),0) original FROM finance_gl_settlement_source_parts p JOIN finance_gl_settlement_reservations r ON r.id=p.reservation_id WHERE p.entry_id=? AND p.allocation_no=? AND r.status IN('RESERVED','COMMITTED')",reference.entryId(),reference.allocationNo());
            BigDecimal local=sum(rows,true).add(decimal(used,"local")).add(decimal(publicClaims,"local"));BigDecimal original=sum(rows,false).add(decimal(used,"original")).add(decimal(publicClaims,"original"));
            if(local.compareTo(source.amountLocal())>0||source.amountOriginal()!=null&&original.compareTo(source.amountOriginal())>0)throw conflict("原期初份额已由其他旧目标或公用清偿使用/预留，请先核对原来源，不能重复认领");
        }
        return new Plan(legacyMap.values().stream().map(l->new Target(l,accounts.get(l.ledgerId()))).toList(),List.copyOf(items));
    }
    private Legacy legacy(UUID id,boolean locked){
        var rows=db.queryForList("""
            SELECT l.*,p.id proof_id,p.initial_state->>'amount_balance' initial_local,p.initial_state->>'amount_balance_original' initial_original,
              ((p.initial_state->>'sourceSnapshotAsOfUtc')::timestamptz AT TIME ZONE 'Asia/Shanghai')::date cutoff_date,
              p.source_row_sha256,p.source_file_sha256,p.target_snapshot_sha256,fn_is_verified_legacy_opening_target(l.id,l.direction) verified
            FROM ar_ap_ledger l JOIN legacy_finance_import_sources p ON p.run_id=l.legacy_import_run_id AND p.target_id=l.id AND p.target_table='ar_ap_ledger'
            WHERE l.id=?
            """+(locked?" FOR UPDATE OF l":""),id);
        if(rows.size()!=1||!Boolean.TRUE.equals(rows.getFirst().get("verified")))throw conflict("旧目标缺少已核初始未结、真实原币或来源证明，保留待核，不按名称或金额猜配");var r=rows.getFirst();
        if(r.get("initial_local")==null||r.get("initial_original")==null||r.get("cutoff_date")==null)throw conflict("旧初始未结或截止日期缺少受验来源");
        BigDecimal local=new BigDecimal(r.get("initial_local").toString()),original=new BigDecimal(r.get("initial_original").toString());
        if(decimal(r,"amount_balance").compareTo(local)!=0||decimal(r,"amount_balance_original").compareTo(original)!=0)throw conflict("旧目标已有截止日后收付款或抵销，请先按原业务核对并撤回相应动作，再接续原期初");
        boolean ar="AR".equals(r.get("direction"));var stable=new LinkedHashMap<String,Object>();for(String field:List.of("id","proof_id","currency_id","client_id","supplier_id","source_row_sha256","source_file_sha256","target_snapshot_sha256","initial_local","initial_original","cutoff_date"))stable.put(field,r.get(field));
        return new Legacy(id,(UUID)r.get("proof_id"),ar?"CUSTOMER":"SUPPLIER",(UUID)r.get(ar?"client_id":"supplier_id"),(UUID)r.get("currency_id"),date(r.get("cutoff_date")),local,original,hash(stable),Objects.toString(r.get("bill_no"),""));
    }
    @Override @Transactional(readOnly=true)
    public Binding read(UUID ledgerId){
        var rows=db.queryForList("SELECT t.*,p.initial_state FROM finance_native_legacy_opening_targets t JOIN finance_native_legacy_opening_reviews r ON r.id=t.review_id AND r.status='APPROVED' JOIN legacy_finance_import_sources p ON p.id=t.legacy_proof_id WHERE t.ledger_id=?",ledgerId);
        if(rows.isEmpty())return null;if(rows.size()!=1)throw conflict("旧目标出现多个生效接续，不能继续清偿");var t=rows.getFirst();
        var amounts=db.queryForMap("SELECT (initial_state->>'amount_balance')::numeric local,(initial_state->>'amount_balance_original')::numeric original FROM legacy_finance_import_sources WHERE id=?",t.get("legacy_proof_id"));
        var entries=db.query("""
            SELECT p.*,e.voucher_id,e.direction,a.original_currency_id,a.currency_id,a.account_code,e.style_id,
              a.auxiliary_id,a.auxiliary_role,a.party_id_snapshot,a.source_system,a.source_code,a.source_name
            FROM finance_native_legacy_opening_parts p JOIN finance_gl_entry_allocations a ON a.entry_id=p.entry_id AND a.allocation_no=p.allocation_no
            JOIN gl_entries e ON e.id=p.entry_id WHERE p.review_id=? AND p.ledger_id=? ORDER BY p.entry_id,p.allocation_no
            """,(rs,n)->new FinancialFrozenDebtReadPort.Entry("REVIEWED_LEGACY_OPENING_SHARE",rs.getObject("voucher_id",UUID.class),rs.getObject("entry_id",UUID.class),rs.getInt("allocation_no"),rs.getObject("style_id",UUID.class),rs.getString("account_code"),rs.getObject("currency_id",UUID.class),new FinancialAuxiliaryValidationPort.Ref(rs.getObject("auxiliary_id",UUID.class),rs.getString("auxiliary_role"),rs.getObject("party_id_snapshot",UUID.class),rs.getString("source_system"),rs.getString("source_code"),rs.getString("source_name")),rs.getObject("original_currency_id",UUID.class),rs.getBigDecimal("amount_original"),rs.getBigDecimal("amount_local"),rs.getInt("direction"),rs.getString("source_fingerprint")),t.get("review_id"),ledgerId);
        return new Binding((UUID)t.get("review_id"),decode(t.get("account_snapshot").toString(),NativeFinancialPostingAccountPort.Account.class),entries,decimal(amounts,"local"),decimal(amounts,"original"),t.get("legacy_fingerprint").toString());
    }
    private Map<String,Object> review(UUID id,boolean locked){var rows=db.queryForList("SELECT * FROM finance_native_legacy_opening_reviews WHERE id=?"+(locked?" FOR UPDATE":""),id);if(rows.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"期初接续记录不存在");return rows.getFirst();}
    private static boolean sameScope(NativeFinancialPostingAccountPort.Account a,NativeFinancialPostingAccountPort.Account b){return Objects.equals(a.styleId(),b.styleId())&&Objects.equals(a.accountCode(),b.accountCode())&&Objects.equals(a.accountingCurrencyId(),b.accountingCurrencyId())&&Objects.equals(a.originalCurrencyId(),b.originalCurrencyId())&&Objects.equals(a.auxiliary().auxiliaryId(),b.auxiliary().auxiliaryId());}
    private static BigDecimal sum(List<Item> rows,boolean local){return rows.stream().map(i->local?i.request().amountLocal():i.request().nativeOriginal()).reduce(BigDecimal.ZERO,BigDecimal::add);}
    private String encode(Object v){try{return json.writeValueAsString(v);}catch(Exception e){throw invalid("期初接续证据无法保存");}}
    private <T>T decode(String value,Class<T> type){try{return json.readValue(value,type);}catch(Exception e){throw conflict("原接续快照无法读取，请保留原记录核对");}}
    private String hash(Object v){return ImmutableDocumentStore.digest(encode(v).getBytes(java.nio.charset.StandardCharsets.UTF_8));}
    private static BigDecimal decimal(Map<String,Object> r,String field){if(r.get(field)==null)throw conflict("原来源缺少明确金额字段，保留待核");return(BigDecimal)r.get(field);}
    private static LocalDate date(Object v){return v instanceof java.sql.Date d?d.toLocalDate():(LocalDate)v;}
    private static void equal(BigDecimal a,BigDecimal b,String field){if(a.compareTo(b)!=0)throw invalid(field+"分配未守恒，原数据未改");}
    private static ApiException invalid(String v){return new ApiException(ErrorCode.VALIDATION_FAILED,v);}
    private static ApiException conflict(String v){return new ApiException(ErrorCode.CONFLICT,v);}
}
