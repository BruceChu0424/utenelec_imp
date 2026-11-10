package com.uten.imp.features.finance.gl;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.concurrency.PaymentStyleHierarchyLock;
import com.uten.imp.application.port.*;
import com.uten.imp.common.files.document.DocumentIntakeProfile;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.*;
import com.uten.imp.security.*;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.time.*;
import java.util.*;
import static com.uten.imp.features.finance.gl.FinanceAccountingContracts.*;
import static com.uten.imp.application.port.FinancialAuxiliaryValidationPort.*;

/** A reviewed, atomic opening + complete-month continuation. It never overlays existing business GL. */
@Service @RequiredArgsConstructor
public class FinanceAccountingImportService {
    @org.springframework.beans.factory.annotation.Autowired
    private com.uten.imp.common.readsnapshot.VersionedSummaryPages summaryPages;

    private final JdbcTemplate db;private final EntityManager em;private final ObjectMapper json;
    private final ImmutableDocumentStore files;private final SecurityContextCurrentUser current;private final TxSessionVars tx;
    private final FinanceDocumentAccessPolicy access;private final FinancialAuxiliaryValidationPort auxiliary;
    private final FinancialAuxiliarySourceReadPort auxiliarySources;
    private final FinancialChartCurrencyReadPort chartCurrencies;
    private void authorize(){CurrentAuthorityGuard.requireAll("finance_report:view","finance_post:execute");FinanceCompanyReportAccess.require(access);}
    private void lock(){db.query("SELECT pg_advisory_xact_lock(hashtextextended('uten:finance-accounting-import',0))",rs->{});}
    private void periodLock(String period){db.query("SELECT pg_advisory_xact_lock(hashtextextended(?,0))",rs->{},"uten:gl:auto-period:"+period);}
    private record Stored(UUID id,UUID actor,String system,String hash,String status,long version,String kind,
                          FinanceAccountingWorkbookParser.Parsed source,String review,String result,UUID submittedBy,UUID paired) { }
    private record Reviewed(Submit request,Plan plan) { }
    private Stored stored(UUID id,boolean locked) {
        var values=db.queryForList("SELECT id,actor_id,source_system,sha256,status,row_version,kind,preview::text,reviewed_input::text,result::text,submitted_by,paired_import_id FROM finance_accounting_import_batches WHERE id=?"+(locked?" FOR UPDATE":""),id);
        if(values.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"原账套导入批次不存在");var row=values.getFirst();
        var item=new Stored(id,(UUID)row.get("actor_id"),row.get("source_system").toString(),row.get("sha256").toString(),row.get("status").toString(),((Number)row.get("row_version")).longValue(),row.get("kind").toString(),
                decode(row.get("preview").toString(),FinanceAccountingWorkbookParser.Parsed.class),(String)row.get("reviewed_input"),(String)row.get("result"),(UUID)row.get("submitted_by"),(UUID)row.get("paired_import_id"));
        if(item.status().equals("PREVIEW")&&!item.actor().equals(current.requireId()))throw new ApiException(ErrorCode.FORBIDDEN,"该预览属于其他账号");return item;
    }
    @Transactional(readOnly=true) public List<Map<String,Object>> recent() {
        authorize();return db.queryForList("SELECT id,kind,source_name AS \"sourceName\",source_system AS \"sourceSystem\",status,row_version AS version,actor_id AS \"actorId\",submitted_by AS \"submittedBy\" FROM finance_accounting_import_batches WHERE actor_id=? OR status<>'PREVIEW' ORDER BY created_at DESC,id LIMIT 40",current.requireId());
    }
    @Transactional(readOnly=true) public Map<String,Object> options() {
        authorize();return Map.of("currencies",chartCurrencies.choices());
    }
    @Transactional(readOnly=true) public Preview get(UUID id) {
        authorize();var item=stored(id,false);String name=db.queryForObject("SELECT source_name FROM finance_accounting_import_batches WHERE id=?",String.class,id);
        return new Preview(id,item.kind(),name,item.system(),item.hash(),item.status(),item.version(),item.submittedBy(),item.source(),item.review()==null?null:decode(item.review(),Reviewed.class),item.result()==null?null:decode(item.result(),Result.class));
    }
    @Transactional(readOnly=true) public List<FinanceAccountingWorkbookParser.Issue> compare(UUID id,UUID balanceId) {
        authorize();var vouchers=stored(id,false);var balances=stored(balanceId,false);
        if(!vouchers.system().equals(balances.system())||!vouchers.actor().equals(balances.actor()))throw invalid("请选择同一提交人、原账套的凭证及余额文件");
        var result=new ArrayList<FinanceAccountingWorkbookParser.Issue>();result.addAll(vouchers.source().issues());result.addAll(balances.source().issues());
        if(result.isEmpty()){result.addAll(FinanceAccountingWorkbookParser.reconcile(vouchers.source(),balances.source()));}return List.copyOf(result);
    }
    @Transactional public Preview preview(String kind,String sourceSystem,String filename,byte[] bytes) {
        authorize();if(!Set.of("VOUCHERS","BALANCE").contains(kind))throw invalid("请选择原凭证或科目余额");
        if(sourceSystem==null||sourceSystem.isBlank()||sourceSystem.length()>80)throw invalid("请填写原账套标识，与辅助明细资料保持一致");
        tx.bind();lock();String hash=ImmutableDocumentStore.digest(bytes),system=sourceSystem.strip();
        var old=db.queryForList("SELECT id FROM finance_accounting_import_batches WHERE actor_id=? AND sha256=? AND source_system=?",UUID.class,current.requireId(),hash,system);
        if(!old.isEmpty()){
            files.checkLegacy("FINANCE_ACCOUNTING_IMPORT_REPLAY",bytes);var previous=stored(old.getFirst(),true);
            // Completed/submitted intent remains immutable. Only an explicit new preview
            // may validate a legacy PREVIEW against its complete original workbook.
            if(previous.status().equals("PREVIEW")&&previous.source().columnContractVersion()!=com.uten.imp.common.importing.ImportColumnGuard.VERSION){
                throw conflict("原账套文件及旧检测结果是不可改写证据；请将原Excel另存为新文件后重新检测，原批次和回执保留");
            }
            return get(old.getFirst());
        }
        String name=filename==null?"source.xls":filename.replaceAll("[\\\\/:*?\"<>|\\p{Cntrl}]","_");if(name.isBlank()||name.length()>240)throw invalid("文件名称无效");
        var parsed=FinanceAccountingWorkbookParser.parse(kind,name,bytes);UUID id=UUID.randomUUID();
        var file=files.save("FINANCE_ACCOUNTING_IMPORT",name,name.toLowerCase(Locale.ROOT).endsWith(".xls")?"application/vnd.ms-excel":"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",bytes,DocumentIntakeProfile.FINANCIAL_TEMPLATE);
        db.update("INSERT INTO finance_accounting_import_batches(id,actor_id,kind,source_system,source_name,sha256,storage_provider,storage_key,storage_version,storage_size,preview) VALUES(?,?,?,?,?,?,?,?,?,?,?::jsonb)",
                id,current.requireId(),kind,system,name,hash,file.provider(),file.key(),file.version(),file.size(),encode(parsed));
        db.update("INSERT INTO attachment_object_outbox(operation,storage_provider,storage_key,storage_version,dedupe_key) VALUES('DELETE_STAGING',?,?,?,?) ON CONFLICT(dedupe_key) DO NOTHING",file.provider(),file.key(),file.version(),file.provider()+"|DELETE_STAGING|"+file.key()+"|"+Objects.toString(file.version(),"<local>"));
        return get(id);
    }
    @Transactional public Preview submit(UUID id,Submit request) {
        authorize();tx.bind();lock();if(request==null||request.balanceImportId()==null)throw invalid("请选择对应期间的完整科目余额批次");
        var vouchers=stored(id,true);if(!vouchers.actor().equals(current.requireId()))throw new ApiException(ErrorCode.FORBIDDEN,"只能提交自己的原文件");
        if(vouchers.status().equals("SUBMITTED")||vouchers.status().equals("POSTED")) {
            if(json.valueToTree(decode(vouchers.review(),Reviewed.class).request()).equals(json.valueToTree(request)))return get(id);
            throw conflict("该批次已提交，修改前请先撤回");
        }
        if(!vouchers.status().equals("PREVIEW")||vouchers.version()!=request.expectedVersion())throw conflict("导入批次状态或版本已变化");
        var balances=stored(request.balanceImportId(),true);
        if(!balances.actor().equals(vouchers.actor())||!balances.status().equals("PREVIEW")||balances.version()!=request.balanceVersion())throw conflict("余额批次属于其他账号、已提交或版本已变化");
        Plan plan=prepare(vouchers,balances,request,vouchers.actor());String reviewed=encode(new Reviewed(request,plan));
        for(var item:List.of(vouchers,balances))db.update("UPDATE finance_accounting_import_batches SET status='SUBMITTED',row_version=row_version+1,paired_import_id=?,reviewed_input=?::jsonb,submitted_by=?,submitted_at=now(),reason=? WHERE id=?",
                item.id().equals(id)?balances.id():id,reviewed,current.requireId(),request.reason().strip(),item.id());
        return get(id);
    }
    @Transactional public Result approve(UUID id,Review request) {
        authorize();tx.bind();lock();String replay=operationReplay(id,"APPROVE",request);
        if(replay!=null)return decode(replay,Result.class);
        var vouchers=stored(id,true);
        if(vouchers.result()!=null){operationResult(id,"APPROVE",request,vouchers.result());return decode(vouchers.result(),Result.class);}
        requireReview(vouchers,request);if(vouchers.submittedBy().equals(current.requireId()))throw conflict("提交人与复核人必须是不同账号");
        var balances=stored(vouchers.paired(),true);var reviewed=decode(vouchers.review(),Reviewed.class);
        if(!balances.status().equals("SUBMITTED")||!Objects.equals(balances.paired(),id))throw conflict("成对余额批次状态已变化");
        var plan=prepare(vouchers,balances,reviewed.request(),vouchers.submittedBy());
        if(!json.valueToTree(plan).equals(json.valueToTree(reviewed.plan())))throw conflict("提交后科目、辅助身份或源资料已变化，请退回重新核对");
        String period=YearMonth.of(plan.year(),plan.month()).toString();periodLock(period);periodLock(YearMonth.from(plan.effectiveFrom().minusDays(1)).toString());
        db.execute("LOCK TABLE gl_entries IN SHARE ROW EXCLUSIVE MODE");
        // Existing native, legacy or other-import entries are not proof of non-duplication.
        if(reviewed.request().appendPeriod())validateAppend(plan,vouchers,balances,reviewed.request());
        else if(db.queryForObject("SELECT count(*) FROM gl_entries WHERE NOT is_deleted",Long.class)!=0
                ||db.queryForObject("SELECT count(*) FROM finance_gl_opening_baselines b JOIN finance_accounting_import_batches batch ON batch.id=b.import_batch_id WHERE batch.status='POSTED' AND batch.reversed_at IS NULL",Long.class)!=0)
            throw conflict("该账套已存在总账或有效期初基准，不能再次首次接续；后续月份请选择继续导入并核对期初");
        var ids=new ArrayList<UUID>();int entries=0;
        for(var journal:plan.journals()) {
            if(journal.lines().isEmpty()||reviewed.request().appendPeriod()&&journal.purpose().equals("OPENING"))continue;
            UUID voucherId=UUID.randomUUID();ids.add(voucherId);String sourceNo="SRC-"+id+"-"+journal.number();
            db.update("INSERT INTO gl_vouchers(id,voucher_no,period,voucher_date,source,source_type,source_doc_id,remark,status,created_by,updated_by) VALUES(?,?,?,?, 'IMPORT','FINANCIAL_SOURCE',?,?,1,?,?)",voucherId,sourceNo,YearMonth.from(journal.date()).toString(),journal.date(),id,request.reason().strip(),current.requireId(),current.requireId());
            int lineNo=0;
            for(var line:journal.lines()){UUID entryId=UUID.randomUUID();
                db.update("INSERT INTO gl_entries(id,voucher_id,line_no,style_id,direction,amount,entry_date,period,source_doc_type,source_doc_id,source_bill_no,summary,created_by,updated_by) VALUES(?,?,?,?,?,?,?,?, 'FINANCIAL_SOURCE',?,?,?,?,?)",
                        entryId,voucherId,++lineNo,line.styleId(),line.direction(),line.amount(),journal.date(),YearMonth.from(journal.date()).toString(),id,journal.number(),line.summary(),current.requireId(),current.requireId());
                allocation(entryId,line);entries++;
                if(journal.purpose().equals("OPENING")&&line.auxiliary()!=null)openingEvidence(balances,line,entryId,plan.effectiveFrom(),vouchers.submittedBy());
            }
            db.update("INSERT INTO finance_gl_voucher_evidence(voucher_id,import_batch_id,purpose,source_system,source_ledger,source_year,source_period,source_voucher_type,source_voucher_no,source_voucher_id,source_sha256,source_snapshot,submitted_by,approved_by) VALUES(?,?,?,?,?,?,?,?,?,?,?,?::jsonb,?,?)",
                    voucherId,id,journal.purpose(),vouchers.system(),plan.ledger(),plan.year(),plan.month(),journal.type(),journal.number(),journal.sourceId(),journal.purpose().equals("OPENING")?balances.hash():vouchers.hash(),encode(journal),vouchers.submittedBy(),current.requireId());
        }
        for(var zero:plan.zeroOpenings())openingEvidence(balances,new Line(zero.accountCode(),null,zero.currencyId(),1,BigDecimal.ZERO,zero.originalNet(),zero.exchangeRate(),zero.auxiliary(),zero.accountName(),zero.accountName(),zero.sourceRow(),"ZERO:"+zero.sourceRow(),"原辅助期初为零",Map.of("sha256",zero.sha256(),"auxiliarySourceId",zero.sourceImportId().toString(),"sourceReference",Objects.toString(zero.sourceReference(),"")),zero.originalCurrencyId()),null,plan.effectiveFrom(),vouchers.submittedBy());
        var result=new Result(id,balances.id(),"POSTED",List.copyOf(ids),entries);String encoded=encode(result);
        for(var item:List.of(vouchers,balances))db.update("UPDATE finance_accounting_import_batches SET status='POSTED',result=?::jsonb,approved_by=?,approved_at=now(),row_version=row_version+1 WHERE id=?",encoded,current.requireId(),item.id());
        if(!reviewed.request().appendPeriod())db.update("INSERT INTO finance_gl_opening_baselines(effective_from,import_batch_id,source_sha256,verified_by) VALUES(?,?,?,?)",plan.effectiveFrom(),id,balances.hash(),current.requireId());
        db.update("INSERT INTO finance_gl_period_versions(period) VALUES(?) ON CONFLICT DO NOTHING",period);
        db.update("INSERT INTO finance_accounting_period_coverage(period,entries_revision,source_kind,import_batch_id,source_sha256,verified_by) SELECT period,revision,'ORIGINAL_BALANCE_AND_COMPLETE_JOURNALS',?,?,? FROM finance_gl_period_versions WHERE period=? ON CONFLICT(period) DO UPDATE SET entries_revision=EXCLUDED.entries_revision,source_kind=EXCLUDED.source_kind,import_batch_id=EXCLUDED.import_batch_id,source_sha256=EXCLUDED.source_sha256,verified_by=EXCLUDED.verified_by,verified_at=now()",id,vouchers.hash(),current.requireId(),period);
        operationResult(id,"APPROVE",request,encoded);
        return result;
    }
    @Transactional public Preview reject(UUID id,Review request){return reset(id,request,false);}
    @Transactional public Preview withdraw(UUID id,Review request){return reset(id,request,true);}
    private Preview reset(UUID id,Review request,boolean own) {
        authorize();tx.bind();lock();String action=own?"WITHDRAW":"REJECT",replay=operationReplay(id,action,request);
        if(replay!=null)return decode(replay,Preview.class);
        var item=stored(id,true);requireReview(item,request);
        if(own!=item.submittedBy().equals(current.requireId()))throw conflict(own?"只能撤回自己提交的批次":"请由另一位复核人退回");
        var pair=stored(item.paired(),true);if(!pair.status().equals("SUBMITTED")||!Objects.equals(pair.paired(),id))throw conflict("成对批次状态不一致");
        for(var value:List.of(item,pair))db.update("UPDATE finance_accounting_import_batches SET status='PREVIEW',row_version=row_version+1,reason=?,paired_import_id=NULL WHERE id=?",request.reason().strip(),value.id());
        // A reviewer may return a batch to its owner but cannot then read the owner's private preview.
        var result=new Preview(id,item.kind(),"",item.system(),item.hash(),"PREVIEW",item.version()+1,item.submittedBy(),null,null,null);
        operationResult(id,action,request,encode(result));return result;
    }
    private void requireReview(Stored item,Review request){if(request==null||!item.status().equals("SUBMITTED")||item.version()!=request.expectedVersion()||!item.kind().equals("VOUCHERS"))throw conflict("凭证批次状态或版本已变化");reason(request.reason());}
    private String operationReplay(UUID id,String action,Review request) {
        if(request==null||request.requestId()==null)throw invalid("请保留原复核请求编号后重试");reason(request.reason());
        var rows=db.queryForList("SELECT actor_id,import_id,action,fingerprint,result::text FROM finance_accounting_review_operations WHERE request_id=?",request.requestId());
        if(rows.isEmpty())return null;var row=rows.getFirst();
        String fingerprint=ImmutableDocumentStore.digest(encode(request).getBytes(java.nio.charset.StandardCharsets.UTF_8));
        if(!current.requireId().equals(row.get("actor_id"))||!id.equals(row.get("import_id"))||!action.equals(row.get("action"))||!fingerprint.equals(row.get("fingerprint")))throw conflict("该复核请求编号已使用，请保留原动作和参数核对");
        return row.get("result").toString();
    }
    private void operationResult(UUID id,String action,Review request,String result) {
        db.update("INSERT INTO finance_accounting_review_operations(request_id,actor_id,import_id,action,fingerprint,result) VALUES(?,?,?,?,?,?::jsonb)",request.requestId(),current.requireId(),id,action,ImmutableDocumentStore.digest(encode(request).getBytes(java.nio.charset.StandardCharsets.UTF_8)),result);
    }
    private Plan prepare(Stored vouchers,Stored balances,Submit request,UUID submitter) {
        com.uten.imp.common.importing.ImportColumnGuard.requireValidated(vouchers.source().columnContractVersion());
        com.uten.imp.common.importing.ImportColumnGuard.requireValidated(balances.source().columnContractVersion());
        reason(request.reason());if(!request.completeOriginalPeriod())throw invalid("需确认原凭证为完整期间，不得用部分凭证认证零发生额");
        if(!vouchers.kind().equals("VOUCHERS")||!balances.kind().equals("BALANCE")||!vouchers.system().equals(balances.system()))throw invalid("原凭证、余额类型或原账套不一致");
        if(!vouchers.source().issues().isEmpty()||!balances.source().issues().isEmpty())throw invalid("请先处理原文件解析问题，未入账");
        PaymentStyleHierarchyLock.lock(em);
        db.query("SELECT pg_advisory_xact_lock(hashtextextended('uten:finance-chart',0))",rs->{});
        var verifiedBalances=zeroEndingProfitBalances(vouchers.source(),balances.source(),request);
        if(!FinanceAccountingWorkbookParser.reconcile(vouchers.source(),verifiedBalances).isEmpty())throw invalid("逐科目发生额核对未通过，请查看比对问题；零余额损益省略项可单独复核，未入账");
        var all=vouchers.source().vouchers();var first=all.getFirst();
        if(all.stream().anyMatch(v->!v.ledger().equals(first.ledger())||v.year()!=first.year()||v.month()!=first.month()||!v.company().equals(first.company())))throw invalid("每次接续只允许一个原账套单位和会计期间");
        var accounts=targets(request.accounts(),verifiedBalances.balances());
        Set<UUID> baseIds=new HashSet<>();chartCurrencies.choices().stream().filter(FinancialChartCurrencyReadPort.Choice::baseCurrency).forEach(choice->baseIds.add(choice.id()));
        Set<UUID> currencyIds=new HashSet<>();chartCurrencies.choices().forEach(choice->currencyIds.add(choice.id()));
        Map<String,Ref> refs=new HashMap<>();Map<String,Line> detailScope=new LinkedHashMap<>();Map<String,List<Line>> openingByCode=new HashMap<>();var zeros=new ArrayList<ZeroOpening>();
        var auxiliarySourceIds=request.auxiliarySourceIds()==null?List.<UUID>of():request.auxiliarySourceIds();
        if(auxiliarySourceIds.size()>20||new HashSet<>(auxiliarySourceIds).size()!=auxiliarySourceIds.size())throw invalid("辅助期初来源最多20份，不能重复选择");
        LocalDate from=LocalDate.of(first.year(),first.month(),1);var month=YearMonth.from(from);
        for(UUID sourceId:auxiliarySourceIds) {
            var source=auxiliarySources.readForAccounting(sourceId);
            if(!source.valid()||!source.actorId().equals(submitter)||!source.sourceSystem().equals(vouchers.system())||!source.dateFrom().equals(from)||!source.dateTo().equals(month.atEndOfMonth()))throw invalid("辅助资料须为同一提交人、原账套、币别和完整期间的原始文件");
            for(var row:source.rows()) {
                UUID rowCurrency=row.currencyId();
                var account=accounts.get(row.accountCode());if(account==null||rowCurrency==null||!account.currencyId().equals(rowCurrency))throw invalid("辅助原表科目币别尚未冻结或与当前对应不同，请重新核对原文件");
                Ref ref=auxiliary.resolveImported(row.accountCode(),source.sourceSystem(),source.role(),row.partyCode(),rowCurrency);
                String key=row.accountCode()+"|"+ref.auxiliaryId();
                var sourceMap=Map.of("auxiliarySourceId",sourceId.toString(),"sha256",source.sha256(),"debit",row.debit().toPlainString(),"credit",row.credit().toPlainString(),"openingDebit",row.openingDebit().toPlainString(),"openingCredit",row.openingCredit().toPlainString());
                Line detail=new Line(row.accountCode(),account.styleId(),rowCurrency,1,BigDecimal.ZERO,null,null,ref,row.accountName(),row.accountName(),row.sourceRow(),"OPEN:"+key,"原辅助期初",sourceMap);
                if(detailScope.putIfAbsent(key,detail)!=null)throw invalid("同科目辅助项目在原始资料中重复，不能重复期初");
                BigDecimal signed=row.openingDebit().subtract(row.openingCredit());
                if(signed.signum()==0)zeros.add(new ZeroOpening(row.accountCode(),rowCurrency,ref,row.accountName(),row.sourceRow(),sourceId,source.sha256(),baseIds.contains(rowCurrency)?BigDecimal.ZERO:null,baseIds.contains(rowCurrency)?BigDecimal.ONE:null,null));
                else openingByCode.computeIfAbsent(row.accountCode(),code->new ArrayList<>()).add(new Line(row.accountCode(),account.styleId(),rowCurrency,signed.signum(),signed.abs(),baseIds.contains(rowCurrency)?signed.abs():null,baseIds.contains(rowCurrency)?BigDecimal.ONE:null,ref,row.accountName(),row.accountName(),row.sourceRow(),"OPEN:"+key,"原辅助期初",sourceMap));
            }
        }
        var manual=request.openingAllocations()==null?List.<OpeningAllocation>of():request.openingAllocations();
        if(manual.size()>2000)throw invalid("一次辅助期初分配最多2000行");
        Map<String,OpeningAllocation> overrides=new HashMap<>();
        Map<String,FinanceAccountingWorkbookParser.Balance> sourceBalances=new HashMap<>();verifiedBalances.balances().forEach(row->sourceBalances.put(row.accountCode(),row));
        for(var item:manual) {
            if(item==null||item.auxiliaryId()==null||item.currencyId()==null||item.sourceReference()==null||item.sourceReference().isBlank()||item.sourceReference().length()>1000||item.accountPathName()!=null&&item.accountPathName().length()>500)throw invalid("请选择辅助项目、币别并填写期初分配来源");
            var account=accounts.get(item.accountCode());var source=sourceBalances.get(item.accountCode());
            if(account==null||source==null||!account.currencyId().equals(item.currencyId()))throw invalid("期初分配科目或币别与原余额不一致");
            if(item.openingDebit()==null&&item.openingCredit()==null)throw invalid("请明确填写期初借方或贷方；无余额请明确填0");
            BigDecimal debit=com.uten.imp.common.util.FinancialExactAmount.book(item.openingDebit()==null?BigDecimal.ZERO:item.openingDebit(),"期初借方"),credit=com.uten.imp.common.util.FinancialExactAmount.book(item.openingCredit()==null?BigDecimal.ZERO:item.openingCredit(),"期初贷方");
            if(debit.signum()<0||credit.signum()<0||debit.signum()*credit.signum()!=0)throw invalid("每个辅助期初只填一个借贷方向，不跨对象冲净");
            BigDecimal signed=debit.subtract(credit);
            if(item.originalNet()!=null){com.uten.imp.common.util.FinancialExactAmount.require(item.originalNet(),"原币期初");if(signed.signum()!=0&&item.originalNet().signum()!=0&&signed.signum()!=item.originalNet().signum())throw invalid("原币期初与本币借贷方向不一致");}
            if(item.exchangeRate()!=null){com.uten.imp.common.util.FinancialExactAmount.require(item.exchangeRate(),"原币期初汇率");if(item.exchangeRate().signum()<=0)throw invalid("汇率应大于0");}
            UUID originalCurrency=item.originalCurrencyId()==null?item.originalNet()==null?null:item.currencyId():item.originalCurrencyId();
            if(originalCurrency!=null&&!currencyIds.contains(originalCurrency))throw invalid("请选择原币金额真实使用的币别");
            if(baseIds.contains(item.currencyId())&&(originalCurrency==null||originalCurrency.equals(item.currencyId()))&&item.originalNet()!=null&&item.originalNet().compareTo(signed)!=0)throw invalid("同一本位币的原额与本币期初应一致");
            Ref ref=auxiliary.inspect(new Selection(item.accountCode(),item.auxiliaryId(),item.currencyId()));
            if(ref==null||!ref.sourceSystem().equals(vouchers.system()))throw invalid("请选择当前原账套的真实辅助项目");
            String key=item.accountCode()+"|"+ref.auxiliaryId();
            if(overrides.putIfAbsent(key,item)!=null)throw invalid("同科目辅助项目不能重复手工分配期初");
            var old=detailScope.get(key);
            if(old!=null) {
                if(debit.compareTo(new BigDecimal(old.source().get("openingDebit")))!=0||credit.compareTo(new BigDecimal(old.source().get("openingCredit")))!=0)throw invalid("补充原币资料不能修改已选原辅助表的本币期初");
                continue;
            }
            var sourceMap=Map.of("kind","MANUAL_OPENING_ALLOCATION","sourceReference",item.sourceReference(),"sha256",balances.hash(),"openingDebit",debit.toPlainString(),"openingCredit",credit.toPlainString());
            String path=item.accountPathName()==null||item.accountPathName().isBlank()?source.accountName():item.accountPathName();
            Line detail=new Line(item.accountCode(),account.styleId(),item.currencyId(),1,BigDecimal.ZERO,null,null,ref,source.accountName(),path,source.sourceRow(),"MANUAL_OPEN:"+key,"财务受审期初分配",sourceMap);detailScope.put(key,detail);
            if(signed.signum()==0)zeros.add(new ZeroOpening(item.accountCode(),item.currencyId(),ref,path,source.sourceRow(),balances.id(),balances.hash()));
            else openingByCode.computeIfAbsent(item.accountCode(),code->new ArrayList<>()).add(new Line(item.accountCode(),account.styleId(),item.currencyId(),signed.signum(),signed.abs(),null,null,ref,source.accountName(),path,source.sourceRow(),"MANUAL_OPEN:"+key,"财务受审期初分配",sourceMap));
        }
        for(var lines:openingByCode.values())for(int index=0;index<lines.size();index++) {
            var line=lines.get(index);var item=overrides.get(line.accountCode()+"|"+line.auxiliary().auxiliaryId());if(item==null)continue;
            var metadata=new LinkedHashMap<>(line.source());metadata.put("sourceReference",item.sourceReference());
            UUID originalCurrency=item.originalCurrencyId()==null?item.originalNet()==null?null:item.currencyId():item.originalCurrencyId();
            boolean sameCurrency=baseIds.contains(line.currencyId())&&(originalCurrency==null||originalCurrency.equals(line.currencyId()));
            BigDecimal original=sameCurrency?line.amount():item.originalNet()==null?null:item.originalNet().multiply(BigDecimal.valueOf(line.direction()));
            lines.set(index,new Line(line.accountCode(),line.styleId(),line.currencyId(),line.direction(),line.amount(),original,sameCurrency?BigDecimal.ONE:item.exchangeRate(),line.auxiliary(),line.accountName(),item.accountPathName()==null||item.accountPathName().isBlank()?line.pathName():item.accountPathName(),line.sourceRow(),line.sourceEntryId(),line.summary(),metadata,sameCurrency?line.currencyId():originalCurrency));
        }
        for(int index=0;index<zeros.size();index++) {
            var zero=zeros.get(index);var item=overrides.get(zero.accountCode()+"|"+zero.auxiliary().auxiliaryId());if(item==null)continue;
            UUID originalCurrency=item.originalCurrencyId()==null?item.originalNet()==null?null:item.currencyId():item.originalCurrencyId();
            boolean sameCurrency=baseIds.contains(zero.currencyId())&&(originalCurrency==null||originalCurrency.equals(zero.currencyId()));
            zeros.set(index,new ZeroOpening(zero.accountCode(),zero.currencyId(),zero.auxiliary(),zero.accountName(),zero.sourceRow(),zero.sourceImportId(),zero.sha256(),sameCurrency?BigDecimal.ZERO:item.originalNet(),sameCurrency?BigDecimal.ONE:item.exchangeRate(),item.sourceReference(),sameCurrency?zero.currencyId():originalCurrency));
        }
        var journals=new ArrayList<Journal>();var opening=new ArrayList<Line>();var selections=new ArrayList<Selection>();
        for(var row:verifiedBalances.balances()) {
            var account=accounts.get(row.accountCode());var detail=openingByCode.getOrDefault(row.accountCode(),List.of());
            boolean hasDetail=detailScope.values().stream().anyMatch(line->line.accountCode().equals(row.accountCode()));
            BigDecimal amount=row.openingDebit().subtract(row.openingCredit());
            if(hasDetail) {
                if(detail.stream().map(line->line.amount().multiply(BigDecimal.valueOf(line.direction()))).reduce(BigDecimal.ZERO,BigDecimal::add).compareTo(amount)!=0)throw invalid("科目"+row.accountCode()+"的原辅助期初与科目余额不一致");
                opening.addAll(detail);
            }else if(amount.signum()!=0){
                selections.add(new Selection(row.accountCode(),null,account.currencyId()));
                opening.add(new Line(row.accountCode(),account.styleId(),account.currencyId(),amount.signum(),amount.abs(),baseIds.contains(account.currencyId())?amount.abs():null,baseIds.contains(account.currencyId())?BigDecimal.ONE:null,null,row.accountName(),row.accountName(),row.sourceRow(),"OPEN:"+row.accountCode(),"原科目期初",Map.of()));
            }
        }
        // Required auxiliary accounts cannot be replaced by an unassigned aggregate opening.
        if(!selections.isEmpty())auxiliary.validateForPosting(selections);
        journals.add(new Journal("OPENING","OPENING","OPENING-"+month,balances.id().toString(),from.minusDays(1),"OPENING",List.copyOf(opening)));
        if(request.voucherPurposes()==null||request.voucherPurposes().size()!=all.size())throw invalid("请逐凭证复核业务性质，结转候选不能自动批准");
        Map<String,BigDecimal[]> auxiliaryMovements=new HashMap<>();selections.clear();
        for(var voucher:all) {
            String purpose=request.voucherPurposes().get(voucher.key());
            if(purpose==null||!Set.of("OPERATING","PNL_CLOSE","PRIOR_YEAR_ADJUSTMENT","RECLASSIFICATION").contains(purpose))throw invalid("请明确每张凭证的业务性质");
            if(voucher.closingCandidate()!=purpose.equals("PNL_CLOSE"))throw invalid("损益结转结构与所选性质不一致，请先核对原始凭证");
            var lines=new ArrayList<Line>();
            for(var entry:voucher.entries()) {
                var account=accounts.get(entry.accountCode());Ref ref=null;UUID selected=request.entryAuxiliaries()==null?null:request.entryAuxiliaries().get(entry.sourceEntryId());
                if(selected!=null)ref=auxiliary.inspect(new Selection(entry.accountCode(),selected,account.currencyId()));
                else if(!entry.customerCode().isBlank()&&entry.supplierCode().isBlank())ref=refs.computeIfAbsent(entry.accountCode()+"|CUSTOMER|"+entry.customerCode(),key->auxiliary.resolveImported(entry.accountCode(),vouchers.system(),"CUSTOMER",entry.customerCode(),account.currencyId()));
                else if(!entry.supplierCode().isBlank()&&entry.customerCode().isBlank())ref=refs.computeIfAbsent(entry.accountCode()+"|SUPPLIER|"+entry.supplierCode(),key->auxiliary.resolveImported(entry.accountCode(),vouchers.system(),"SUPPLIER",entry.supplierCode(),account.currencyId()));
                if(ref!=null&&(!ref.sourceSystem().equals(vouchers.system())||ref.role().equals("CUSTOMER")&&!entry.customerCode().isBlank()&&!ref.sourceCode().equals(entry.customerCode())||ref.role().equals("SUPPLIER")&&!entry.supplierCode().isBlank()&&!ref.sourceCode().equals(entry.supplierCode())))throw invalid("显式辅助选择与原分录辅助编号不一致");
                selections.add(new Selection(entry.accountCode(),ref==null?null:ref.auxiliaryId(),account.currencyId()));
                UUID originalCurrency=null;
                if(!entry.currencyName().isBlank()) {
                    originalCurrency=request.sourceCurrencyMappings()==null?null:request.sourceCurrencyMappings().get(entry.currencyName());
                    if(originalCurrency==null&&entry.currencyName().equals(sourceBalances.get(entry.accountCode()).currencyName()))originalCurrency=account.currencyId();
                    if(originalCurrency==null||!currencyIds.contains(originalCurrency))throw invalid("请明确原凭证币别“"+entry.currencyName()+"”对应哪个真实币别，不按名称猜配");
                }else if(baseIds.contains(account.currencyId()))originalCurrency=account.currencyId();
                boolean sameCurrency=originalCurrency!=null&&baseIds.contains(originalCurrency);
                if(sameCurrency&&!entry.currencyName().isBlank()&&entry.original()!=null&&entry.original().compareTo(entry.amount())!=0)throw invalid("原分录原额与本位币不同，请先核实原币币别对应");
                var line=new Line(entry.accountCode(),account.styleId(),account.currencyId(),entry.direction(),entry.amount(),sameCurrency?entry.amount():entry.currencyName().isBlank()?null:entry.original(),sameCurrency?BigDecimal.ONE:entry.exchangeRate(),ref,entry.accountName(),entry.accountName(),entry.sourceRow(),entry.sourceEntryId(),entry.summary(),entry.source(),originalCurrency);lines.add(line);
                if(ref!=null){var sums=auxiliaryMovements.computeIfAbsent(entry.accountCode()+"|"+ref.auxiliaryId(),key->new BigDecimal[]{BigDecimal.ZERO,BigDecimal.ZERO});sums[entry.direction()==1?0:1]=sums[entry.direction()==1?0:1].add(entry.amount());}
            }
            journals.add(new Journal(voucher.key(),voucher.type(),voucher.number(),voucher.sourceVoucherId(),voucher.date(),purpose,List.copyOf(lines)));
        }
        auxiliary.validateForPosting(selections);
        for(var scope:detailScope.entrySet()) {
            var line=scope.getValue();var sums=auxiliaryMovements.getOrDefault(scope.getKey(),new BigDecimal[]{BigDecimal.ZERO,BigDecimal.ZERO});
            if(line.source().containsKey("debit")&&(sums[0].compareTo(new BigDecimal(line.source().get("debit")))!=0||sums[1].compareTo(new BigDecimal(line.source().get("credit")))!=0))throw invalid("原辅助明细与逐凭证发生额不一致："+line.accountCode()+"/"+line.auxiliary().sourceCode());
        }
        for(var entry:auxiliaryMovements.entrySet())if(!detailScope.containsKey(entry.getKey()))throw invalid("分录辅助项目缺少期初及零余额依据，请导入完整辅助明细");
        var allLines=journals.stream().flatMap(journal->journal.lines().stream()).toList();
        validateAll(allLines.stream().map(line->new Selection(line.accountCode(),line.auxiliary()==null?null:line.auxiliary().auxiliaryId(),line.currencyId())).toList());
        auxiliary.validateForPosting(zeros.stream().map(zero->new Selection(zero.accountCode(),zero.auxiliary().auxiliaryId(),zero.currencyId())).toList());
        for(var journal:journals)if(journal.lines().stream().map(line->line.amount().multiply(BigDecimal.valueOf(line.direction()))).reduce(BigDecimal.ZERO,BigDecimal::add).signum()!=0)throw invalid("接续凭证借贷不平，未补差");
        return new Plan(from,first.ledger(),first.company(),first.year(),first.month(),List.copyOf(journals),List.copyOf(zeros),List.copyOf(request.accounts()),List.copyOf(auxiliarySourceIds));
    }
    private Map<String,AccountSelection> targets(List<AccountSelection> selected,List<FinanceAccountingWorkbookParser.Balance> source) {
        if(selected==null||selected.size()!=source.size())throw invalid("请明确原余额每个科目的核算UUID和币别，不按名称猜配");
        Map<String,AccountSelection> result=new LinkedHashMap<>();
        var currencies=chartCurrencies.read(new HashSet<>(source.stream().map(row->row.accountCode()).toList()));
        for(var account:selected) {
            if(account==null||account.styleId()==null||account.currencyId()==null||result.putIfAbsent(account.accountCode(),account)!=null)throw invalid("科目对应缺少UUID/币别或代码重复");
            Integer count=db.queryForObject("SELECT count(*) FROM finance_chart_codes c JOIN finance_chart_code_styles m ON m.code=c.code JOIN payment_styles s ON s.id=m.style_id WHERE c.code=? AND c.row_version=? AND m.style_id=? AND NOT s.is_deleted AND NOT EXISTS(SELECT 1 FROM payment_styles child WHERE child.parent_id=s.id AND NOT child.is_deleted) AND EXISTS(SELECT 1 FROM currencies WHERE id=?)",Integer.class,account.accountCode(),account.chartVersion(),account.styleId(),account.currencyId());
            if(count!=1)throw conflict("财务科目对应或版本已变化："+account.accountCode());
            var currency=currencies.get(account.accountCode());
            if(currency==null||currency.currencyId()==null||!currency.currencyId().equals(account.currencyId()))throw invalid("请先在科目对应中核实该原账套科目的币别："+account.accountCode());
        }
        if(!result.keySet().equals(new HashSet<>(source.stream().map(row->row.accountCode()).toList())))throw invalid("科目对应范围与原余额文件不一致");return result;
    }
    private void validateAll(List<Selection> selections){for(int start=0;start<selections.size();start+=2000)auxiliary.validateForPosting(selections.subList(start,Math.min(start+2000,selections.size())));}
    private void validateAppend(Plan plan,Stored vouchers,Stored balances,Submit request) {
        LocalDate before=plan.effectiveFrom().minusDays(1),end=YearMonth.from(plan.effectiveFrom()).atEndOfMonth();
        if(!FinancialPeriodCoverage.asOf(em,before).complete())throw conflict("前期来源尚未完整核对，不能跳过缺少月份继续导入");
        if(db.queryForObject("SELECT count(*) FROM finance_gl_opening_baselines b JOIN finance_accounting_import_batches initial ON initial.id=b.import_batch_id WHERE b.effective_from<=? AND initial.status='POSTED' AND initial.reversed_at IS NULL AND initial.source_system=? AND initial.reviewed_input->'plan'->>'ledger'=?",Integer.class,
                plan.effectiveFrom(),vouchers.system(),plan.ledger())!=1)throw conflict("后续月份须沿用首次接续的原账套标识和原账套编号");
        if(db.queryForObject("SELECT count(*) FROM gl_entries WHERE NOT is_deleted AND entry_date>=? AND entry_date<=?",Long.class,plan.effectiveFrom(),end)!=0)throw conflict("所选月份已存在总账分录，不能重复叠加原凭证");
        var verified=zeroEndingProfitBalances(vouchers.source(),balances.source(),request);
        Map<String,BigDecimal> opening=new HashMap<>();
        db.query("SELECT m.code,COALESCE(sum(e.direction*e.amount),0) FROM finance_chart_code_styles m LEFT JOIN gl_entries e ON e.style_id=m.style_id AND NOT e.is_deleted AND e.entry_date<=? GROUP BY m.code",rs->{opening.put(rs.getString(1),rs.getBigDecimal(2));},before);
        for(var row:verified.balances())if(row.openingDebit().subtract(row.openingCredit()).compareTo(opening.getOrDefault(row.accountCode(),BigDecimal.ZERO))!=0)throw conflict("后续月份的原期初与系统上期期末不一致："+row.accountCode());
        var sourceCodes=new HashSet<>(verified.balances().stream().map(row->row.accountCode()).toList());
        for(var value:opening.entrySet())if(value.getValue().signum()!=0&&!sourceCodes.contains(value.getKey()))throw conflict("后续余额文件遗漏了上期非零科目："+value.getKey());
        Map<String,BigDecimal> actualAux=new HashMap<>();
        db.query("SELECT a.account_code,a.auxiliary_id,a.currency_id,sum(e.direction*a.amount_local) FROM finance_gl_entry_allocations a JOIN gl_entries e ON e.id=a.entry_id WHERE a.auxiliary_id IS NOT NULL AND NOT e.is_deleted AND e.entry_date<=? GROUP BY a.account_code,a.auxiliary_id,a.currency_id",rs->{actualAux.put(rs.getString(1)+"|"+rs.getObject(2)+"|"+rs.getObject(3),rs.getBigDecimal(4));},before);
        var sourceAux=new HashMap<String,BigDecimal>();
        for(var journal:plan.journals())if(journal.purpose().equals("OPENING"))for(var line:journal.lines())if(line.auxiliary()!=null)
            sourceAux.merge(line.accountCode()+"|"+line.auxiliary().auxiliaryId()+"|"+line.currencyId(),line.amount().multiply(BigDecimal.valueOf(line.direction())),BigDecimal::add);
        for(var zero:plan.zeroOpenings())sourceAux.putIfAbsent(zero.accountCode()+"|"+zero.auxiliary().auxiliaryId()+"|"+zero.currencyId(),BigDecimal.ZERO);
        for(var source:sourceAux.entrySet())if(source.getValue().compareTo(actualAux.getOrDefault(source.getKey(),BigDecimal.ZERO))!=0)throw conflict("后续月份原辅助期初与上期辅助余额不一致");
        for(var source:actualAux.entrySet())if(source.getValue().signum()!=0&&!sourceAux.containsKey(source.getKey()))throw conflict("后续原辅助明细遗漏了上期非零余额对象");
    }
    private FinanceAccountingWorkbookParser.Parsed zeroEndingProfitBalances(FinanceAccountingWorkbookParser.Parsed vouchers,
            FinanceAccountingWorkbookParser.Parsed balances,Submit request) {
        var reviewed=request.omittedZeroBalanceProfitCodes()==null?Set.<String>of():request.omittedZeroBalanceProfitCodes();
        if(reviewed.size()>200)throw invalid("零余额损益省略项超过完整复核范围");
        var codes=new HashSet<>(balances.balances().stream().map(row->row.accountCode()).toList());
        var added=new ArrayList<>(balances.balances());
        for(String code:reviewed) {
            if(code==null||codes.contains(code))throw invalid("零余额损益复核只适用于原余额表实际省略的科目");
            var entries=vouchers.vouchers().stream().flatMap(voucher->voucher.entries().stream()).filter(entry->code.equals(entry.accountCode())).toList();
            if(entries.isEmpty())throw invalid("省略项在原凭证中没有发生依据");
            var names=db.queryForList("SELECT c.name FROM finance_chart_codes c JOIN finance_chart_code_styles m ON m.code=c.code JOIN payment_styles s ON s.id=m.style_id WHERE c.code=? GROUP BY c.code,c.name HAVING bool_and(s.category IN('INCOME','EXPENSE'))",String.class,code);
            if(names.size()!=1)throw invalid("请先新增并对应明确的收入/费用科目，再复核零余额省略项；不能按代码前缀猜类别");
            BigDecimal debit=entries.stream().map(entry->entry.debit()).reduce(BigDecimal.ZERO,BigDecimal::add);
            BigDecimal credit=entries.stream().map(entry->entry.credit()).reduce(BigDecimal.ZERO,BigDecimal::add);
            if(debit.compareTo(credit)!=0)throw invalid("省略损益科目的整期借贷尚未结平，不能认作期初期末均为零");
            var first=entries.getFirst();
            added.add(new FinanceAccountingWorkbookParser.Balance(first.sourceRow(),first.year(),first.month(),code,names.getFirst(),first.currencyName(),
                    BigDecimal.ZERO,BigDecimal.ZERO,debit,credit,BigDecimal.ZERO,BigDecimal.ZERO));
        }
        return new FinanceAccountingWorkbookParser.Parsed("BALANCE",List.of(),List.copyOf(added),balances.issues(),balances.headers());
    }
    private void allocation(UUID entryId,Line line) {
        var ref=line.auxiliary();db.update("INSERT INTO finance_gl_entry_allocations(entry_id,allocation_no,account_code,source_account_code,source_account_name,source_account_path_name,auxiliary_id,currency_id,amount_local,amount_original,exchange_rate,auxiliary_role,party_id_snapshot,source_system,source_code,source_name,source_entry_id,source_row,source_snapshot,created_by,original_currency_id) VALUES(?,1,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?::jsonb,?,?)",
                entryId,line.accountCode(),line.accountCode(),line.accountName(),line.pathName(),ref==null?null:ref.auxiliaryId(),line.currencyId(),line.amount(),line.original(),line.exchangeRate(),ref==null?null:ref.role(),ref==null?null:ref.partyId(),ref==null?null:ref.sourceSystem(),ref==null?null:ref.sourceCode(),ref==null?null:ref.sourceName(),line.sourceEntryId(),line.sourceRow(),encode(line.source()),current.requireId(),line.originalCurrencyId());
    }
    private void openingEvidence(Stored balances,Line line,UUID entryId,LocalDate date,UUID submitter) {
        var ref=line.auxiliary();db.update("INSERT INTO finance_gl_auxiliary_opening_evidence(import_batch_id,account_code,auxiliary_id,currency_id,effective_from,opening_debit,opening_credit,entry_id,auxiliary_role,party_id_snapshot,source_system,source_code,source_name,source_account_code,source_account_name,source_account_path_name,source_sha256,source_row,submitted_by,approved_by,opening_original,exchange_rate,source_reference,original_currency_id) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                balances.id(),line.accountCode(),ref.auxiliaryId(),line.currencyId(),date,line.direction()==1?line.amount():BigDecimal.ZERO,line.direction()==-1?line.amount():BigDecimal.ZERO,entryId,ref.role(),ref.partyId(),ref.sourceSystem(),ref.sourceCode(),ref.sourceName(),line.accountCode(),line.accountName(),line.pathName(),line.source().getOrDefault("sha256",balances.hash()),line.sourceRow(),submitter,current.requireId(),line.original()==null?null:entryId==null?line.original():line.original().multiply(BigDecimal.valueOf(line.direction())),line.exchangeRate(),line.source().get("sourceReference"),line.originalCurrencyId());
    }
    private static void reason(String reason){if(reason==null||reason.isBlank()||reason.length()>1000)throw invalid("请填写1至1000字的接续/复核依据");}
    private String encode(Object value){try{return json.writeValueAsString(value);}catch(Exception error){throw new IllegalStateException("原账套来源保存失败",error);}}
    private <T>T decode(String value,Class<T> type){try{return json.readValue(value,type);}catch(Exception error){throw new IllegalStateException("原账套来源读取失败",error);}}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}

    /** Full selected lifecycle range through bounded summary batches; original detail/write contracts are unchanged. */
    public com.uten.imp.common.readsnapshot.VersionedSummaryPages.Page<Map<String,Object>> summaries(String requestedScope,int page,int size,String revision) {
        authorize();UUID actor=current.requireId();
        String scope=com.uten.imp.common.readsnapshot.VersionedSummaryPages.scope(requestedScope);
        String where="(actor_id=? OR status<>'PREVIEW')"+switch(scope) {
            case "active" -> " AND (status IN ('PREVIEW','SUBMITTED'))";
            case "history" -> " AND (status IN ('POSTED','REJECTED','CANCELLED'))";
            default -> "";
        };
        var request=new com.uten.imp.common.readsnapshot.VersionedSummaryPages.Request("finance-accounting-imports","finance",Map.of("actor",actor,"lifecycleContract","accounting-import-lifecycle-v2"),scope,page,size,1000,revision);
        return summaryPages.page(request,()->{authorize();},
                ()->db.queryForObject("SELECT count(*) FROM finance_accounting_import_batches WHERE "+where,Long.class,actor),
                (readPage,readSize)->db.queryForList("SELECT id,kind,source_name AS \"sourceName\",source_system AS \"sourceSystem\",status,row_version AS version,actor_id AS \"actorId\",submitted_by AS \"submittedBy\" FROM finance_accounting_import_batches WHERE "+where+" ORDER BY created_at DESC,id DESC LIMIT ? OFFSET ?",actor,readSize,Math.multiplyExact((long)readPage-1,readSize)));
    }
}
