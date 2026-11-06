package com.uten.imp.features.finance.payables;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.concurrency.PaymentStyleHierarchyLock;
import com.uten.imp.application.port.*;
import com.uten.imp.common.finance.*;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.*;
import com.uten.imp.features.finance.arap.ArApLedgerService;
import com.uten.imp.features.finance.gl.*;
import com.uten.imp.security.*;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.*;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.time.LocalDate;
import java.util.*;
import java.util.function.Supplier;

/** Original-document decisions. A release owns one negative AP and its exact native offset, never a cash payment. */
@Service @RequiredArgsConstructor
public class FinancePayableStatementAdjustmentService implements FinancePayableStatementAdjustmentPort {
    @org.springframework.beans.factory.annotation.Autowired
    private com.uten.imp.common.readsnapshot.VersionedSummaryPages summaryPages;

    private final JdbcTemplate db;
    private final EntityManager em;
    private final ObjectMapper json;
    private final SecurityContextCurrentUser current;
    private final TxSessionVars tx;
    private final FinanceDocumentAccessPolicy access;
    private final FinanceStatementOriginalReadPort originals;
    private final NativeFinancialPostingAccountPort nativeAccounts;
    private final FinancialFrozenDebtReadPort frozenDebts;
    private final FinancialAuxiliaryValidationPort auxiliaries;
    private final FinancialChartCurrencyReadPort currencies;
    private final FinancePayableClassificationPort classifications;
    private final FinanceControlledJournalService journals;
    private final GlPostingService periods;
    private final ArApLedgerService ledgers;
    private final SupplierOpenItemOffsetService offsets;
    private final SupplierClosedPeriodGuard closed;
    private final SupplierPayableHoldGuard holds;

    private record Item(Planned preview,NativeFinancialPostingAccountPort.Account counterpart,FinancePayableClassificationPort.Target classification,FinancialFrozenDebtReadPort.Debt frozenDebt){ }
    private record Plan(Context context,FinanceStatementOriginalReadPort.Original original,LocalDate effectiveDate,
            List<Item> items,String precisionChoicesJson,String planHash){ }
    public record PreviewInput(Context context,List<Line> lines){ }

    @Transactional(readOnly=true)
    public Map<String,Object> choices(Context context){return choices(context,1,50);}
    @Transactional(readOnly=true)
    public Map<String,Object> choices(Context context,int page,int size){return choices(context,page,size,1);}
    @Transactional(readOnly=true)
    public Map<String,Object> choices(Context context,int page,int size,int adjustmentPage){
        read();var original=original(context);var targets=new ArrayList<Map<String,Object>>();int p=Math.max(1,page),s=Math.max(1,Math.min(100,size));
        String sourceJson=encode(original.sources().stream().map(source->Map.of("kind",source.sourceType(),"id",source.sourceId())).toList());
        String scope=" FROM ar_ap_ledger ledger JOIN jsonb_to_recordset(?::jsonb) AS source(kind text,id uuid) ON source.kind=ledger.source_doc_type AND source.id=ledger.source_doc_id WHERE ledger.direction='AP' AND ledger.status=1 AND NOT ledger.is_deleted AND ledger.supplier_id=? AND ledger.currency_id=?";
        long total=db.queryForObject("SELECT count(*)"+scope,Long.class,sourceJson,original.partyId(),original.currencyId());
        var rows=db.queryForList("SELECT ledger.*"+scope+" ORDER BY ledger.bill_date,ledger.bill_no,ledger.id LIMIT ? OFFSET ?",sourceJson,original.partyId(),original.currencyId(),s,(long)(p-1)*s);
        for(var row:rows){
                if(!Objects.equals(original.partyId(),row.get("supplier_id"))||!Objects.equals(original.currencyId(),row.get("currency_id")))continue;
                var item=new LinkedHashMap<String,Object>();
                item.put("ledgerId",row.get("id"));item.put("billNo",row.get("bill_no"));item.put("sourceDocNo",row.get("source_doc_no"));
                item.put("sourceType",row.get("source_doc_type"));item.put("sourceId",row.get("source_doc_id"));
                item.put("balanceOriginal",money(row,"amount_balance_original").toPlainString());item.put("balanceLocal",money(row,"amount_balance").toPlainString());
                item.put("fingerprint",targetFingerprint(row));targets.add(item);
        }
        var accounts=db.queryForList("SELECT style.id,code.code,code.name,style.category FROM finance_chart_code_styles mapping JOIN finance_chart_codes code ON code.code=mapping.code JOIN payment_styles style ON style.id=mapping.style_id WHERE code.classification='PROFIT' AND style.category IN('INCOME','EXPENSE') AND style.status='使用' AND NOT style.is_deleted ORDER BY code.sort_order,code.code,style.id");
        var result=new LinkedHashMap<String,Object>();
        result.put("original",Map.of("reviewId",original.reviewId(),"documentSha256",original.documentSha256(),"periodAmountOriginal",original.periodAmount().toPlainString(),"dateFrom",original.dateFrom(),"dateTo",original.dateTo()));
        result.put("targets",targets);result.put("accounts",accounts);result.put("page",p);result.put("totalPages",(total+s-1)/s);result.put("total",total);
        result.put("currency",db.queryForMap("SELECT code,name FROM currencies WHERE id=?",original.currencyId()));
        int ap=Math.max(1,adjustmentPage);long adjustmentCount=db.queryForObject("SELECT count(*) FROM finance_payable_statement_adjustments WHERE statement_review_id=? AND source_fingerprint=?",Long.class,original.reviewId(),original.sourceFingerprint());
        result.put("adjustments",adjustmentRows(context,ap));result.put("adjustmentPage",ap);result.put("adjustmentPages",(adjustmentCount+49)/50);result.put("adjustmentTotal",adjustmentCount);result.put("adjustmentSize",50);result.put("size",s);return result;
    }
    @Override @Transactional(readOnly=true)
    public Preview preview(Context context,List<Line> lines){read();return previewOf(plan(context,lines,false,null));}

    @Override @Transactional
    public UUID submit(Submit request){
        write();if(request==null||request.requestId()==null||request.context()==null)throw invalid("请保留原件及本次提交编号");
        reference(request.sourceReference(),"本次处理依据");tx.bind();requestLock(request.requestId());String payloadHash=hash(encode(request));
        var replay=db.queryForList("SELECT id,payload_hash,created_by FROM finance_payable_statement_adjustments WHERE request_id=?",request.requestId());
        if(!replay.isEmpty()){
            var row=replay.getFirst();if(!payloadHash.equals(row.get("payload_hash"))||!current.requireId().equals(row.get("created_by")))throw conflict("该提交编号已有不同内容，请保留原完整请求核对结果");return (UUID)row.get("id");
        }
        return usingChoices(request.precisionChoicesJson(),()->{
            var plan=plan(request.context(),request.lines(),true,null);
            if(!Objects.equals(plan.planHash(),request.expectedPlanHash()))throw conflict("原件、应付余额、分类或科目已变化，请保留输入重新预览");
            UUID id=UUID.randomUUID();var preview=previewOf(plan);var original=plan.original();
            db.update("""
                INSERT INTO finance_payable_statement_adjustments(id,request_id,payload_hash,statement_review_id,source_fingerprint,document_sha256,
                  supplier_id,currency_id,effective_date,period_amount_original,released_original,released_local,plan_hash,plan,precision_choices,source_reference,created_by)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?::jsonb,?::jsonb,?,?)
                """,id,request.requestId(),payloadHash,original.reviewId(),original.sourceFingerprint(),original.documentSha256(),original.partyId(),original.currencyId(),
                    plan.effectiveDate(),original.periodAmount(),new BigDecimal(preview.releasedOriginal()),new BigDecimal(preview.releasedLocal()),plan.planHash(),encode(plan),plan.precisionChoicesJson(),request.sourceReference(),current.requireId());
            int sequence=0;
            for(var item:plan.items()){
                var p=item.preview();var input=p.input();
                db.update("""
                    INSERT INTO finance_payable_statement_adjustment_lines(id,adjustment_id,line_no,target_ledger_id,target_fingerprint,decision,fee_kind,category,
                      amount_original,amount_local,target_before_original,target_after_original,target_before_local,target_after_local,debt_account,counterpart_account,
                      counterpart_style_id,counterpart_auxiliary_id,attribution_reference,source_reference)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?::jsonb,?::jsonb,?,?,?,?)
                    """,UUID.randomUUID(),id,++sequence,input.targetLedgerId(),p.targetFingerprint(),input.decision().name(),input.feeKind().name(),input.category(),input.amountOriginal(),new BigDecimal(p.amountLocal()),
                        new BigDecimal(p.targetBeforeOriginal()),new BigDecimal(p.targetAfterOriginal()),new BigDecimal(p.targetBeforeLocal()),new BigDecimal(p.targetAfterLocal()),p.debtAccount()==null?null:encode(p.debtAccount()),item.counterpart()==null?null:encode(item.counterpart()),
                        input.counterpartStyleId(),input.counterpartAuxiliaryId(),input.attributionReference(),input.sourceReference());
            }
            return id;
        });
    }

    @Override @Transactional
    public List<Effect> approve(UUID id){
        write();tx.bind();var row=adjustment(id,true);
        if("APPROVED".equals(row.get("status")))return effects(id);
        if(!"DRAFT".equals(row.get("status")))throw conflict("该处理已反审，请保留原记录另建版本");
        if(current.requireId().equals(row.get("created_by")))throw conflict("手续费/尾数处理须由另一名财务审核人核对");
        var saved=decode(row.get("plan").toString(),Plan.class);
        return usingChoices(saved.precisionChoicesJson(),()->{
            var checked=plan(saved.context(),saved.items().stream().map(i->i.preview().input()).toList(),true,id);
            if(!saved.planHash().equals(checked.planHash()))throw conflict("原应付余额、分类、原件覆盖或科目已变化，请保留原草稿重新核对");
            var records=db.queryForList("SELECT * FROM finance_payable_statement_adjustment_lines WHERE adjustment_id=? ORDER BY line_no",id);
            for(int at=0;at<records.size();at++){
                var line=records.get(at);var item=checked.items().get(at);var p=item.preview();var input=p.input();
                if(input.decision()==Decision.STILL_OWED)continue;
                UUID lineId=(UUID)line.get("id");BigDecimal local=new BigDecimal(p.amountLocal());UUID target=input.targetLedgerId();
                var source=db.queryForMap("SELECT exchange_rate FROM ar_ap_ledger WHERE id=?",target);
                ledgers.postArAp(new ArApLedgerService.ArApPostingRequest("AP","PAYABLE_STATEMENT_CREDIT",lineId,"APF-"+lineId,checked.effectiveDate(),null,
                    checked.original().partyId(),checked.original().currencyId(),money(source,"exchange_rate"),local.negate(),null,input.sourceReference(),input.amountOriginal().negate()));
                UUID credit=db.queryForObject("SELECT id FROM ar_ap_ledger WHERE source_doc_type='PAYABLE_STATEMENT_CREDIT' AND source_doc_id=? AND status=1 AND NOT is_deleted",UUID.class,lineId);
                nativeAccounts.captureStatementCredit(credit,target);UUID voucher=null;
                if(local.signum()>0){
                    var posted=journals.post("APF-"+lineId,checked.effectiveDate(),"PAYABLE_STATEMENT_CREDIT",credit,"PAYABLE_STATEMENT_CREDIT_LINE",input.sourceReference(),
                        List.of(new FinanceControlledJournalService.Entry(p.debtAccount().styleId(),1,local,"对账单逐笔不欠：原冻结应付减少",allocation(p.debtAccount(),input.amountOriginal(),lineId,encode(item))),
                            new FinanceControlledJournalService.Entry(item.counterpart().styleId(),-1,local,"对账单逐笔不欠：财务明确对方科目",allocation(item.counterpart(),input.amountOriginal(),lineId,encode(item)))),current.requireId());
                    voucher=posted.voucherId();nativeAccounts.bindArApEntry(credit,voucher,1,true);
                }
                UUID batch=UUID.randomUUID();offsets.applyBatch(batch,null,credit,checked.original().partyId(),checked.original().currencyId(),checked.effectiveDate(),
                    List.of(new SupplierOpenItemOffsetService.Target(target,input.amountOriginal())),input.sourceReference());
                UUID offset=db.queryForObject("SELECT id FROM supplier_open_item_offsets WHERE offset_batch_id=? AND source_ledger_id=? AND target_ledger_id=?",UUID.class,batch,credit,target);
                classifications.assign(new FinancePayableClassificationPort.Assignment(lineId,credit,target,offset,item.classification().classificationId(),input.category(),input.amountOriginal(),local,local,input.sourceReference()));
                db.update("UPDATE finance_payable_statement_adjustment_lines SET credit_ledger_id=?,offset_batch_id=?,voucher_id=? WHERE id=?",credit,batch,voucher,lineId);
            }
            db.update("UPDATE finance_payable_statement_adjustments SET status='APPROVED',approved_by=?,approved_at=now() WHERE id=? AND status='DRAFT'",current.requireId(),id);
            return effects(id);
        });
    }

    @Override @Transactional
    public List<Effect> reverse(UUID id,String reason){
        write();reference(reason,"反审依据");tx.bind();var row=adjustment(id,true);
        if("REVERSED".equals(row.get("status")))return effects(id);
        if(!"APPROVED".equals(row.get("status")))throw conflict("只能反审已审核的逐单处理");
        LocalDate today=BusinessTime.today();PaymentStyleHierarchyLock.lock(em);periods.lockAutoProjectionPeriod(today);nativeAccounts.requireNoImportedPeriod(today);
        closed.requireOpen((UUID)row.get("supplier_id"),(UUID)row.get("currency_id"),today,"对账单手续费/尾数反审");
        classifications.lockForWrite();
        var records=db.queryForList("SELECT * FROM finance_payable_statement_adjustment_lines WHERE adjustment_id=? ORDER BY line_no DESC",id);
        var ledgerIds=records.stream().filter(r->r.get("credit_ledger_id")!=null).flatMap(r->java.util.stream.Stream.of((UUID)r.get("target_ledger_id"),(UUID)r.get("credit_ledger_id"))).distinct().sorted().toList();
        nativeAccounts.lockDebtSources(ledgerIds,records.stream().map(r->(UUID)r.get("counterpart_style_id")).filter(Objects::nonNull).distinct().toList());
        for(var line:records){
            if(!"RELEASED".equals(line.get("decision")))continue;
            holds.requireUnheld(List.of((UUID)line.get("target_ledger_id")),"对账单手续费/尾数反审");
            offsets.reverseBatch((UUID)line.get("offset_batch_id"),reason);
            var credit=db.queryForMap("SELECT * FROM ar_ap_ledger WHERE id=? FOR UPDATE",line.get("credit_ledger_id"));
            if(money(credit,"amount_offset_original").signum()!=0||money(credit,"amount_offset_local").signum()!=0||money(credit,"amount_settled").signum()!=0
                ||money(credit,"amount_received_original").signum()!=0||money(credit,"amount_write_off_original").signum()!=0)throw conflict("减免贷项仍被其他业务使用，请先按后发生顺序反向");
            UUID reversal=null;
            if(line.get("voucher_id")!=null)reversal=journals.reverse((UUID)line.get("voucher_id"),"APF-REV-"+line.get("id"),today,"PAYABLE_STATEMENT_CREDIT_REV",(UUID)line.get("credit_ledger_id"),"PAYABLE_STATEMENT_CREDIT_REV",reason,current.requireId()).voucherId();
            db.update("UPDATE ar_ap_ledger SET status=-1,is_deleted=true,deleted_at=now(),updated_at=now(),updated_by=? WHERE id=? AND status=1 AND NOT is_deleted",current.requireId(),line.get("credit_ledger_id"));
            if(reversal!=null)db.update("UPDATE finance_payable_statement_adjustment_lines SET reversal_voucher_id=? WHERE id=?",reversal,line.get("id"));
        }
        db.update("UPDATE finance_payable_statement_adjustments SET status='REVERSED',reversed_by=?,reversed_at=now(),reverse_reason=? WHERE id=? AND status='APPROVED'",current.requireId(),reason,id);
        return effects(id);
    }

    @Override @Transactional(readOnly=true)
    public List<Effect> readConfirmed(Context context){read();original(context);var result=new ArrayList<Effect>();for(var row:db.queryForList("SELECT id FROM finance_payable_statement_adjustments WHERE statement_review_id=? AND source_fingerprint=? AND status='APPROVED' ORDER BY approved_at,id",context.statementReviewId(),context.expectedSourceFingerprint())){result.addAll(effects((UUID)row.get("id")));}return List.copyOf(result);}
    @Transactional(readOnly=true)
    public List<Map<String,Object>> list(Context context){read();original(context);return adjustmentRows(context,1);}
    private List<Map<String,Object>> adjustmentRows(Context context,int page){return db.queryForList("SELECT id,effective_date,status,created_by,approved_by,source_reference,released_original::text,released_local::text FROM finance_payable_statement_adjustments WHERE statement_review_id=? AND source_fingerprint=? ORDER BY created_at DESC,id LIMIT 50 OFFSET ?",context.statementReviewId(),context.expectedSourceFingerprint(),(long)(page-1)*50);}
    @Transactional(readOnly=true)
    public Map<String,Object> detail(UUID id){
        read();var row=adjustment(id,false);var saved=decode(row.get("plan").toString(),Plan.class);var display=new LinkedHashMap<String,Object>();
        display.put("context",saved.context());display.put("effectiveDate",saved.effectiveDate());display.put("documentSha256",saved.original().documentSha256());
        display.put("periodAmountOriginal",saved.original().periodAmount().toPlainString());display.put("planHash",saved.planHash());
        display.put("items",saved.items().stream().map(item->{var value=new LinkedHashMap<String,Object>();value.put("preview",item.preview());value.put("counterpart",item.counterpart());return value;}).toList());
        return Map.of("id",id,"status",row.get("status"),"sourceReference",row.get("source_reference"),"plan",display,"effects",effects(id));
    }

    private Plan plan(Context context,List<Line> inputs,boolean lock,UUID excluded){
        var original=original(context);if(inputs==null||inputs.isEmpty()||inputs.size()>200||inputs.stream().anyMatch(Objects::isNull))throw invalid("请逐笔选择1至200项完整的实际手续费/尾数决定");
        if(original.periodAmount().signum()<0)throw conflict("本原件本期金额为负，不自动推断为正应付减免");
        LocalDate day=BusinessTime.today();
        if(lock){PaymentStyleHierarchyLock.lock(em);periods.lockAutoProjectionPeriod(day);nativeAccounts.requireNoImportedPeriod(day);closed.requireOpen(original.partyId(),original.currencyId(),day,"对账单逐笔手续费/尾数");
            classifications.lockForWrite();
            nativeAccounts.lockDebtSources(inputs.stream().map(Line::targetLedgerId).filter(Objects::nonNull).distinct().sorted().toList(),inputs.stream().map(Line::counterpartStyleId).filter(Objects::nonNull).distinct().toList());
            for(UUID target:inputs.stream().map(Line::targetLedgerId).filter(Objects::nonNull).distinct().sorted().toList())db.queryForList("SELECT id FROM ar_ap_ledger WHERE id=? FOR UPDATE",target);
        }
        var targets=new HashMap<UUID,Map<String,Object>>();var originalsLeft=new HashMap<UUID,BigDecimal>();var localsLeft=new HashMap<UUID,BigDecimal>();var unique=new HashSet<String>();var items=new ArrayList<Item>();
        var categoryUsed=new HashMap<String,BigDecimal[]>();BigDecimal releasedOriginal=BigDecimal.ZERO;
        for(var input:inputs){
            if(input==null||input.targetLedgerId()==null||input.decision()==null||input.feeKind()==null)throw invalid("请逐笔明确目标应付、仍欠/不欠和手续费/尾数类别");
            if(!unique.add(input.targetLedgerId()+":"+input.feeKind()))throw invalid("同一应付的同类手续费/尾数请保留一个明确合计决定");
            if(!Set.of("GOODS","MOULD").contains(Objects.toString(input.category(),"")))throw invalid("请逐笔明确货款或模具款归属，不能按金额比例猜分");
            reference(input.attributionReference(),"归属依据");reference(input.sourceReference(),"原来源依据");
            if(input.amountOriginal()==null||input.amountOriginal().signum()<=0)throw invalid("请填写本项明确的正原币金额");FinancialExactAmount.require(input.amountOriginal(),"逐笔原币金额");
            var target=targets.computeIfAbsent(input.targetLedgerId(),ignored->target(original,input.targetLedgerId()));String fp=targetFingerprint(target);
            if(!Objects.equals(fp,input.expectedTargetFingerprint()))throw conflict("目标应付来源或余额指纹已变化，请重新读取原目标，不按单号或同额改配");
            BigDecimal beforeOriginal=originalsLeft.getOrDefault(input.targetLedgerId(),money(target,"amount_balance_original"));
            BigDecimal beforeLocal=localsLeft.getOrDefault(input.targetLedgerId(),money(target,"amount_balance"));
            if(input.amountOriginal().compareTo(beforeOriginal)>0)throw conflict("逐笔金额超过原应付当前未结原币，不能自动替代已付款");
            var debt=nativeAccounts.frozenArAp(input.targetLedgerId());
            FinancialFrozenDebtReadPort.Debt frozenDebt=null;
            NativeFinancialPostingAccountPort.Account counterpart=null;FinancePayableClassificationPort.Target classification=null;
            BigDecimal local=BigDecimal.ZERO,afterOriginal=beforeOriginal,afterLocal=beforeLocal;
            if(input.decision()==Decision.RELEASED){
                if(debt==null||!debt.complete()||debt.auxiliary()==null||!Objects.equals(debt.originalCurrencyId(),original.currencyId()))throw conflict("原应付缺少完整受审科目、辅助或真实原币，请先核对原分录");
                frozenDebt=frozenDebts.readArAp(List.of(input.targetLedgerId())).get(input.targetLedgerId());
                if(frozenDebt==null||!frozenDebt.complete())throw conflict("原应付尚无完整真实已记账分录，请先完成原来源记账，不以本次减免代替原应付");
                holds.requireUnheld(List.of(input.targetLedgerId()),"对账单逐笔不欠处理");
                local=FinancialBookAllocation.part(input.amountOriginal(),beforeOriginal,beforeLocal);
                counterpart=counterpart(input,original.currencyId(),lock);
                classification=classifications.target(input.targetLedgerId());
                if(classification.classificationId()==null)throw conflict("目标应付未明确货款/模具分类，请先完成原来源分类");
                final String category=input.category();var part=classification.parts().stream().filter(p->category.equals(p.category())).findFirst().orElseThrow(()->conflict("原应付缺少所选货款/模具归属，不推断整票类别"));
                String key=input.targetLedgerId()+":"+category;var used=categoryUsed.computeIfAbsent(key,ignored->new BigDecimal[]{BigDecimal.ZERO,BigDecimal.ZERO});
                used[0]=used[0].add(input.amountOriginal());used[1]=used[1].add(local);
                if(part.remainingOriginal()==null||part.remainingLocal()==null)throw conflict("原应付分类剩余金额仍待核对，不能据整票余额猜分本次归属");
                if(used[0].compareTo(part.remainingOriginal())>0||used[1].compareTo(part.remainingLocal())>0)throw conflict("本次多项处理合计超过目标分类剩余原币或本币，请核对货款/模具归属");
                afterOriginal=beforeOriginal.subtract(input.amountOriginal());afterLocal=beforeLocal.subtract(local);releasedOriginal=releasedOriginal.add(input.amountOriginal());
                originalsLeft.put(input.targetLedgerId(),afterOriginal);localsLeft.put(input.targetLedgerId(),afterLocal);
            }else if(input.counterpartStyleId()!=null||input.counterpartAuxiliaryId()!=null)throw invalid("仍欠不产生对方科目分录，请清除该项减免科目选择");
            items.add(new Item(new Planned(input,local.toPlainString(),beforeOriginal.toPlainString(),beforeLocal.toPlainString(),afterOriginal.toPlainString(),afterLocal.toPlainString(),fp,debt,
                counterpart==null?null:counterpart.accountCode(),counterpart==null?null:counterpart.accountingCurrencyId(),Objects.toString(target.get("bill_no"),""),Objects.toString(target.get("source_doc_no"),"")),counterpart,classification,frozenDebt));
        }
        BigDecimal prior=db.queryForObject("SELECT COALESCE(sum(released_original),0) FROM finance_payable_statement_adjustments WHERE statement_review_id=? AND status='APPROVED' AND (?::uuid IS NULL OR id<>?)",BigDecimal.class,original.reviewId(),excluded,excluded);
        if(prior.add(releasedOriginal).compareTo(original.periodAmount())>0)throw conflict("不欠合计超过此原件本期金额；不能以整户余额代替原件金额");
        var policy=new LinkedHashMap<String,Object>();policy.put("version",1);policy.put("choices",new TreeMap<>(BusinessPrecisionContext.choices()));
        String choices=encode(policy);String fingerprint=hash(encode(Arrays.asList(context,original,day,items,choices,prior)));
        return new Plan(context,original,day,List.copyOf(items),choices,fingerprint);
    }
    private Preview previewOf(Plan plan){BigDecimal original=BigDecimal.ZERO,local=BigDecimal.ZERO;for(var item:plan.items()){if(item.preview().input().decision()==Decision.RELEASED){original=original.add(item.preview().input().amountOriginal());local=local.add(new BigDecimal(item.preview().amountLocal()));}}return new Preview(plan.planHash(),plan.original().reviewId(),plan.original().documentSha256(),plan.original().periodAmount().toPlainString(),original.toPlainString(),local.toPlainString(),plan.items().stream().map(Item::preview).toList(),plan.precisionChoicesJson());}
    private FinanceStatementOriginalReadPort.Original original(Context c){
        if(c==null)throw invalid("请选择已独立确认的原对账单");var source=originals.requireConfirmed(c.statementReviewId(),c.expectedSourceFingerprint());
        var ordered=source.sources().stream().sorted(Comparator.comparing(FinanceStatementOriginalReadPort.SourceDocument::sourceType).thenComparing(FinanceStatementOriginalReadPort.SourceDocument::sourceId))
            .map(document->new FinanceStatementOriginalReadPort.SourceDocument(document.sourceType(),document.sourceId(),document.itemIds().stream().sorted().toList())).toList();
        return new FinanceStatementOriginalReadPort.Original(source.reviewId(),source.templateKey(),source.partyRole(),source.partyId(),source.currencyId(),source.dateFrom(),source.dateTo(),source.sourceFingerprint(),source.documentSha256(),source.periodAmount(),ordered);
    }
    private Map<String,Object> target(FinanceStatementOriginalReadPort.Original original,UUID id){
        var rows=db.queryForList("SELECT * FROM ar_ap_ledger WHERE id=? AND direction='AP' AND open_item_kind='PAYABLE' AND status=1 AND NOT is_deleted",id);
        if(rows.size()!=1)throw conflict("原件目标必须是当前有效正式正应付");var row=rows.getFirst();
        if(!Objects.equals(original.partyId(),row.get("supplier_id"))||!Objects.equals(original.currencyId(),row.get("currency_id"))
            ||original.sources().stream().noneMatch(s->Objects.equals(s.sourceType(),row.get("source_doc_type"))&&Objects.equals(s.sourceId(),row.get("source_doc_id"))))throw conflict("此原件没有完整覆盖所选原生应付来源，不能按名称、金额或部分月行代替整票");
        if(money(row,"amount_balance_original").signum()<=0||money(row,"amount_balance").signum()<0)throw conflict("原应付已无可处理的正未结原币");return row;
    }
    private NativeFinancialPostingAccountPort.Account counterpart(Line input,UUID originalCurrency,boolean lock){
        if(input.counterpartStyleId()==null)throw invalid("不欠必须由财务明确选择对方科目");
        var rows=db.queryForList("SELECT code.code,code.classification,style.category FROM finance_chart_code_styles mapping JOIN finance_chart_codes code ON code.code=mapping.code JOIN payment_styles style ON style.id=mapping.style_id WHERE style.id=? AND style.status='使用' AND NOT style.is_deleted",input.counterpartStyleId());
        if(rows.size()!=1||!"PROFIT".equals(rows.getFirst().get("classification"))||!Set.of("INCOME","EXPENSE").contains(rows.getFirst().get("category")))throw invalid("此入口只接受明确损益科目；银行、资产、库存或成本须走其真实业务来源链");
        String code=rows.getFirst().get("code").toString();var currency=currencies.read(Set.of(code)).get(code);
        if(currency==null||currency.currencyId()==null)throw conflict("对方财务科目的会计属性币别仍未核定");
        var selection=new FinancialAuxiliaryValidationPort.Selection(code,input.counterpartAuxiliaryId(),currency.currencyId());
        var ref=lock?auxiliaries.validateForPosting(List.of(selection)).getFirst():auxiliaries.inspect(selection);
        return new NativeFinancialPostingAccountPort.Account(input.counterpartStyleId(),code,currency.currencyId(),ref,originalCurrency,null,currency.chartVersion(),false,true,"财务逐单明确的对方损益科目及真实辅助，非银行费用或库存分录");
    }
    private String targetFingerprint(Map<String,Object> row){var fields=new LinkedHashMap<String,Object>();for(String field:List.of("id","direction","source_doc_type","source_doc_id","supplier_id","currency_id","exchange_rate","amount_original","amount_original_local","amount_balance_original","amount_balance","amount_settled","amount_offset_original","amount_offset_local","status","is_deleted")){fields.put(field,row.get(field));}return hash(encode(fields));}
    private FinanceControlledJournalService.Allocation allocation(NativeFinancialPostingAccountPort.Account a,BigDecimal original,UUID source,String snapshot){return new FinanceControlledJournalService.Allocation(a.accountCode(),a.accountingCurrencyId(),a.auxiliary(),source.toString(),1,snapshot,a.originalCurrencyId(),original,null);}
    private List<Effect> effects(UUID id){return db.query("SELECT line.*,owner.effective_date,owner.status FROM finance_payable_statement_adjustment_lines line JOIN finance_payable_statement_adjustments owner ON owner.id=line.adjustment_id WHERE line.adjustment_id=? ORDER BY line.line_no",(r,n)->new Effect(id,r.getObject("id",UUID.class),r.getObject("target_ledger_id",UUID.class),Decision.valueOf(r.getString("decision")),FeeKind.valueOf(r.getString("fee_kind")),r.getString("category"),r.getBigDecimal("amount_original").toPlainString(),r.getBigDecimal("amount_local").toPlainString(),r.getObject("credit_ledger_id",UUID.class),r.getObject("offset_batch_id",UUID.class),r.getObject("voucher_id",UUID.class),r.getObject("counterpart_style_id",UUID.class),r.getString("attribution_reference"),r.getString("source_reference"),r.getObject("effective_date",LocalDate.class),r.getString("status")),id).stream().map(e->new Effect(e.adjustmentId(),e.lineId(),e.targetLedgerId(),e.decision(),e.feeKind(),e.category(),e.amountOriginal(),e.amountLocal(),e.creditLedgerId(),e.offsetBatchId(),e.voucherId(),e.counterpartStyleId(),e.attributionReference(),e.sourceReference(),e.effectiveDate(),e.status(),effectiveParts(e.lineId()))).toList();}
    private List<EffectivePart> effectiveParts(UUID lineId){return db.query("SELECT * FROM v_finance_payable_statement_adjustment_parts_effective WHERE line_id=? ORDER BY source_category,category",(r,n)->new EffectivePart(r.getString("category"),r.getBigDecimal("amount_original").toPlainString(),r.getBigDecimal("amount_local").toPlainString(),r.getObject("source_classification_id",UUID.class),r.getObject("offset_classification_id",UUID.class),r.getObject("correction_id",UUID.class),r.getString("source_category"),r.getBigDecimal("source_local").toPlainString(),r.getObject("target_classification_id",UUID.class)),lineId);}
    private Map<String,Object> adjustment(UUID id,boolean lock){var rows=db.queryForList("SELECT * FROM finance_payable_statement_adjustments WHERE id=?"+(lock?" FOR UPDATE":""),id);if(rows.size()!=1)throw invalid("逐单处理记录不存在");return rows.getFirst();}
    private <T>T usingChoices(String choices,Supplier<T> action){if(choices==null)return action.get();try(var ignored=BusinessPrecisionContext.use(BusinessPrecisionContext.parse(Base64.getUrlEncoder().withoutPadding().encodeToString(choices.getBytes(StandardCharsets.UTF_8))))){return action.get();}catch(RuntimeException e){throw e;}catch(Exception e){throw new IllegalStateException("无法恢复本次已明确的精度选择",e);}}
    private void requestLock(UUID id){db.query("SELECT pg_advisory_xact_lock(hashtextextended('uten:payable-statement-adjustment:'||?::text,0))",r->{},id);}
    private void read(){CurrentAuthorityGuard.requireAll("finance_report:view","ar_ap_ledger:view");FinanceCompanyReportAccess.require(access);}
    private void write(){read();CurrentAuthorityGuard.requireAll("supplier_settlement:confirm","finance_payment:approve","finance_post:execute");}
    private String encode(Object v){try{return json.writeValueAsString(v);}catch(Exception e){throw invalid("逐单处理快照无法保存");}}
    private <T>T decode(String v,Class<T> type){try{return json.readValue(v,type);}catch(Exception e){throw conflict("原逐单处理快照无法读取，请保留原记录核对");}}
    private static String hash(String v){return ImmutableDocumentStore.digest(v.getBytes(StandardCharsets.UTF_8));}
    private static BigDecimal money(Map<String,Object> row,String key){Object value=row.get(key);if(!(value instanceof BigDecimal amount))throw conflict("原应付金额仍未知："+key);return amount;}
    private static void reference(String v,String label){if(v==null||v.isBlank()||v.length()>2000)throw invalid("请填写"+label+"（最多2000字）");}
    private static ApiException invalid(String v){return new ApiException(ErrorCode.VALIDATION_FAILED,v);}
    private static ApiException conflict(String v){return new ApiException(ErrorCode.CONFLICT,v);}

    /** Independent target/record complete reads share the mutable business domain, not an auth-only epoch. */
    public Map<String,Object> versionedChoices(Context context,int page,int size,int adjustmentPage,String part,String revision) {
        if(context==null||!Set.of("targets","adjustments").contains(part)||page<1||size<1||size>100||adjustmentPage<1)
            throw invalid("完整摘要读取条件无效");
        int selectedPage=part.equals("targets")?page:adjustmentPage;
        int selectedSize=part.equals("targets")?size:50;
        var request=new com.uten.imp.common.readsnapshot.VersionedSummaryPages.Request("finance-payable-statement-choices","finance",
                Map.of("statementReviewId",context.statementReviewId(),"sourceFingerprint",context.expectedSourceFingerprint(),"part",part),
                "all",selectedPage,selectedSize,100,revision);
        var snapshot=summaryPages.read(request,this::read,()->choices(context,page,size,adjustmentPage));
        var result=new LinkedHashMap<String,Object>(snapshot.value());
        result.put("scope","all");result.put("readScopeVersion",snapshot.readScopeVersion());
        result.put("readSnapshotRevision",snapshot.readSnapshotRevision());
        result.put("readDataVersion",snapshot.readDataVersion());
        return result;
    }
}
