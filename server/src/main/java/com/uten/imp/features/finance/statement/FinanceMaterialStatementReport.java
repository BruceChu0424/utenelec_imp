package com.uten.imp.features.finance.statement;

import com.uten.imp.application.port.*;
import com.uten.imp.application.port.FinanceMaterialStatementSourcePort.*;
import com.uten.imp.common.report.*;
import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.util.*;
import com.uten.imp.features.finance.report.*;
import jakarta.persistence.EntityManager;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;
import static com.uten.imp.features.finance.statement.FinanceMaterialStatementContracts.*;
import static com.uten.imp.features.finance.statement.FinanceMaterialStatementService.*;

/** One exact timeline powers the on-screen original table, export and frozen statement original. */
final class FinanceMaterialStatementReport {
    private final FinanceMaterialStatementService s;private final EntityManager em;
    private static final int MAX=20000;
    FinanceMaterialStatementReport(FinanceMaterialStatementService s,EntityManager em){this.s=s;this.em=em;}
    record Projection(List<Map<String,Object>> rows,List<ReportColumn> columns,Map<String,Object> metadata){}
    ReportTableResponse report(UUID aux,UUID currency,UUID selected,String keyword,LocalDate from,LocalDate to,int page,int size,FinanceReportColumnOptions options){
        return present(prepare(aux,currency,selected,from,to),keyword,page,size,options);
    }
    ReportTableResponse snapshot(UUID aux,UUID currency,UUID selected,LocalDate from,LocalDate to){
        return snapshot(prepare(aux,currency,selected,from,to));
    }
    private ReportTableResponse snapshot(Projection projection){
        // Aggregate through the same authorised projection and shared calculator once.
        var aggregate=present(projection,null,1,1,FinanceReportColumnOptions.NONE);
        var emitted=new ArrayList<Map<String,Object>>();var allowed=new LinkedHashSet<String>();projection.columns().forEach(c->allowed.add(c.key()));
        allowed.addAll(List.of("__ordinal","__rowKey","__materialContextId","__sourceType","__sourceId","__effectId","__sourceFingerprint","__rowKind","__flowRole","__notApplicable","__basis","__pending","__billNo"));
        for(var original:projection.rows()){var row=new LinkedHashMap<String,Object>();for(String key:allowed){row.put(key,original.get(key));}com.uten.imp.common.report.ReportQueryKit.includeDecimalTexts(row);emitted.add(row);}
        return new ReportTableResponse(projection.columns(),emitted,Map.of(),1,Math.max(1,emitted.size()),emitted.size(),emitted.isEmpty()?0:1,aggregate.totals(),aggregate.readScopeVersion(),aggregate.statisticsGeneratedAt(),Set.of(),projection.metadata());
    }
    ReportTableResponse reportFromAnchorCohort(UUID anchor,String keyword,LocalDate from,LocalDate to,int page,int size,FinanceReportColumnOptions options){return present(cohort(anchor,from,to),keyword,page,size,options);}
    ReportTableResponse snapshotFromAnchorCohort(UUID anchor,LocalDate from,LocalDate to){return snapshot(cohort(anchor,from,to));}
    Projection cohort(UUID anchor,LocalDate from,LocalDate to){
        var c=s.context(anchor,false);var config=s.approvedContext(anchor);var args=new ArrayList<Object>(List.of(c.get("auxiliary_id"),c.get("accounting_currency_id"),c.get("account_code"),config.amountBasis().name()));
        String original=config.amountBasis()==AmountBasis.ORIGINAL?" AND COALESCE(e.source_snapshot->'effectiveInput',e.input)->>'originalCurrencyId'=?":"";if(config.amountBasis()==AmountBasis.ORIGINAL)args.add(config.originalCurrencyId().toString());
        var ids=s.db.queryForList("SELECT c.id FROM finance_material_contexts c JOIN finance_material_evidence e ON e.context_id=c.id AND e.kind='CONTEXT' AND e.current_approved WHERE c.active AND c.auxiliary_id=? AND c.accounting_currency_id=? AND c.account_code=? AND COALESCE(e.source_snapshot->'effectiveInput',e.input)->>'amountBasis'=?"+original,UUID.class,args.toArray());
        if(!ids.contains(anchor))throw invalid("锚点已不在本次已审分组范围，请刷新");return prepare((UUID)c.get("auxiliary_id"),(UUID)c.get("accounting_currency_id"),null,from,to,new LinkedHashSet<>(ids),anchor);
    }
    Projection prepare(UUID aux,UUID currency,UUID selected,LocalDate from,LocalDate to){return prepare(aux,currency,selected,from,to,null,null);}
    private Projection prepare(UUID aux,UUID currency,UUID selected,LocalDate from,LocalDate to,Set<UUID> cohort,UUID anchor){
        if(aux==null||currency==null||from==null||to==null||from.isAfter(to))throw invalid("请选择明确财务辅助、会计币别及完整对账期间");
        var args=new ArrayList<Object>(List.of(aux,currency));String where=" WHERE active AND auxiliary_id=? AND accounting_currency_id=? AND EXISTS(SELECT 1 FROM finance_material_evidence approved_context WHERE approved_context.context_id=finance_material_contexts.id AND approved_context.kind='CONTEXT' AND approved_context.current_approved)";if(selected!=null){where+=" AND id=?";args.add(selected);}
        if(cohort!=null){where+=" AND id IN("+String.join(",",Collections.nCopies(cohort.size(),"?"))+")";args.addAll(cohort);}
        var contexts=s.db.queryForList("SELECT * FROM finance_material_contexts"+where+" ORDER BY id",args.toArray());if(contexts.isEmpty())throw invalid("该辅助和会计币别还没有明确材料上下文，请先维护原表资料");
        var scope=new ReadScope();var configs=new HashMap<UUID,ContextInput>();
        for(var c:contexts){UUID id=(UUID)c.get("id");scope.contexts.put(id,c);configs.put(id,s.approvedContext(id));}
        var configuration=configs.values().iterator().next();
        if(configs.values().stream().anyMatch(c->c.amountBasis()!=configuration.amountBasis()||c.amountBasis()==AmountBasis.ORIGINAL&&!Objects.equals(c.originalCurrencyId(),configuration.originalCurrencyId())))throw invalid("这些材料上下文的金额口径或实际原币单位不同，请选择单一上下文分别生成，不能混币合计");
        contexts.sort(Comparator.comparingInt(c->configs.get((UUID)c.get("id")).sortOrder()));
        String account=configuration.accountCode();if(configs.values().stream().anyMatch(c->!account.equals(c.accountCode())))throw invalid("所选材料上下文的真实GL科目不同，请分别生成");
        var financialRef=s.auxiliary.inspectHistorical(new FinancialAuxiliaryValidationPort.Selection(account,aux,currency));
        if(financialRef==null||financialRef.partyId()==null)throw invalid("该辅助尚未明确真实往来对象，不能按同名归户");
        var ledger=s.ledger.read(new FinanceAuxiliaryLedgerReadPort.Scope(account,aux,currency,configuration.originalCurrencyId(),from,to));
        UUID displayCurrency=configuration.amountBasis()==AmountBasis.LOCAL?baseCurrency():configuration.originalCurrencyId();
        String currencyLabel=s.db.queryForObject("SELECT COALESCE(NULLIF(code,''),name) FROM currencies WHERE id=?",String.class,displayCurrency);
        var glFacts=glFacts(account,aux,currency,from,to);
        if(configuration.amountBasis()==AmountBasis.ORIGINAL){glFacts=glFacts.stream().filter(row->row.get("original_currency_id")==null||Objects.equals(configuration.originalCurrencyId(),row.get("original_currency_id"))).toList();}var roots=new LinkedHashSet<UUID>();glFacts.forEach(g->roots.add((UUID)g.get("root_id")));
        loadRoots(roots,account,aux,currency,financialRef,scope);
        var feeArgs=new ArrayList<Object>(List.of(aux,currency,account));feeArgs.addAll(roots.stream().map(UUID::toString).toList());
        var feeEvidence=roots.isEmpty()?List.<Map<String,Object>>of():s.db.queryForList("SELECT e.* FROM finance_material_evidence e JOIN finance_material_contexts c ON c.id=e.context_id WHERE e.kind='FEE' AND e.current_approved AND c.auxiliary_id=? AND c.accounting_currency_id=? AND c.account_code=? AND split_part(e.resource_key,':',1) IN("+String.join(",",Collections.nCopies(roots.size(),"?"))+") ORDER BY e.id",feeArgs.toArray());
        var fees=new HashMap<String,Map<String,Object>>();var feeProofKnown=new HashMap<UUID,Boolean>();
        // Read all referenced physical sources in bounded batches once, rather than one query per fee share.
        var feeKeys=new LinkedHashSet<Key>();
        for(var raw:feeEvidence){var e=s.decodeEvidence(raw);fees.put(e.get("resource_key").toString(),e);var v=s.input(e,FeeAssignment.class);if(v.processingParts()!=null)v.processingParts().forEach(p->feeKeys.add(p.outboundSource()));}
        readFacts(new ArrayList<>(feeKeys),scope);
        boolean complete=(configuration.amountBasis()==AmountBasis.LOCAL?ledger.local():ledger.original()).debit()!=null;
        var fingerprintParts=new ArrayList<Object>();fingerprintParts.add(configuration.amountBasis()==AmountBasis.ORIGINAL?ledger.originalFingerprint():ledger.fingerprint());fingerprintParts.add(glFacts);
        for(var g:glFacts){var occurrence=decimal(g.get("occurrence"));if(occurrence==null){complete=false;continue;}if(occurrence.signum()==0)continue;
            String key=g.get("root_id")+":"+g.get("allocation_no");var e=fees.get(key);if(e==null){complete=false;continue;}
            boolean proven=feeProofKnown.computeIfAbsent((UUID)e.get("id"),ignored->{try{return s.validate(e,false,scope).fingerprint().equals(e.get("source_fingerprint"));}catch(com.uten.imp.common.web.ApiException error){return false;}});
            var root=scope.gl.get(new GlAllocationKey((UUID)g.get("root_id"),((Number)g.get("allocation_no")).intValue()));
            if(!proven||root==null||!sameAmount(g.get("amount_local"),root.get("amount_local"))||!sameAmount(g.get("amount_original"),root.get("amount_original"))||!Objects.equals(g.get("original_currency_id"),root.get("original_currency_id")))complete=false;
        }
        var rows=new ArrayList<Map<String,Object>>();BigDecimal closing=BigDecimal.ZERO;boolean closingKnown=true;
        for(var c:contexts){UUID id=(UUID)c.get("id");var config=configs.get(id);var approved=s.approved(id,scope);fingerprintParts.add(approved.stream().map(e->List.of(e.get("id"),Objects.toString(e.get("source_fingerprint"),""))).toList());
            var result=timeline(c,config,approved,scope,glFacts,fees,feeProofKnown,complete,displayCurrency,from,to);
            rows.addAll(result.rows());if(result.closing()==null){closingKnown=false;}else{closing=closing.add(result.closing());}fingerprintParts.add(result.fingerprint());
            if(rows.size()>MAX)throw invalid("原表超过20000行，请按实际期间或材料上下文分段，不能截断后冒充完整原表");
        }
        long ordinal=0;for(var row:rows){
            for(String key:List.of("inWeight","outWeight","loss","outQty","processAmount"))row.put("__sum_"+key,"SUBTOTAL".equals(row.get("__rowKind"))?BigDecimal.ZERO:applicable(row,key));
            if("OPENING".equals(row.get("__rowKind"))&&!Boolean.TRUE.equals(row.get("__processingCoverageComplete")))row.put("__sum_processAmount",null);
            if("OPENING".equals(row.get("__rowKind"))&&!Boolean.TRUE.equals(row.get("__materialCoverageComplete")))for(String key:List.of("inWeight","outWeight","loss","outQty"))row.put("__sum_"+key,null);
            row.put("__ordinal",++ordinal);row.put("__rowKey",row.get("__materialContextId")+"|"+row.get("__rowKind")+"|"+Objects.toString(row.get("__effectId"),"OPENING"));}
        var sidebar=new FinanceMaterialSidebar(s).applicable(contexts.getFirst(),from,to,scope);fingerprintParts.add(sidebar.values().stream().map(e->List.of(e.get("id"),Objects.toString(e.get("source_fingerprint"),""),e.get("__valid"))).toList());var side=sideTables(configs,rows,complete,sidebar);fingerprintParts.add(side);fingerprintParts.add(BusinessPrecisionContext.usedChoices());String fp=s.hash(fingerprintParts);var columns=columns(currencyLabel);
        var metadata=new LinkedHashMap<String,Object>();metadata.put("templateKey","otherReceivableStatement");metadata.put("materialContextId",selected);metadata.put("materialAnchorContextId",anchor);metadata.put("accountCode",account);metadata.put("materialContextIds",contexts.stream().map(c->c.get("id")).toList());metadata.put("canvasColumns",17);metadata.put("sourceMainHeaderRow",3);metadata.put("hiddenColumns",List.of(11,12,13,14,15,16));metadata.put("supplementalWidths",List.of(5.5,24.0,6.3,9.0,7.7,9.8,11.6));metadata.put("auxiliaryId",aux);metadata.put("accountingCurrencyId",currency);metadata.put("currencyId",currency);metadata.put("actualCurrencyId",displayCurrency);metadata.put("currencyName",currencyLabel);metadata.put("amountBasis",configuration.amountBasis());metadata.put("originalCurrencyId",configuration.originalCurrencyId());metadata.put("partyRole",financialRef.role());metadata.put("partyId",financialRef.partyId());metadata.put("partyName",financialRef.sourceName());metadata.put("sourceFingerprint",fp);metadata.put("businessPrecisionChoices",BusinessPrecisionContext.usedChoices());metadata.put("processingAdjustedTotal",null);metadata.put("processingAdjustmentBasis","调整后金额尚待真实附加来源完整核对，不按样例0.87或固定税率扩算，也不将原加工合计冒充调整后金额。");metadata.put("closingWeightKg",closingKnown?closing:null);metadata.put("processingCoverageComplete",complete);metadata.put("physicalDateBasis","SOURCE_BUSINESS：仅真实已确认movement形成物量，正向归原收货/出库业务单日期；实际确认/反向日另保留核对。回看晚确认会补全原业务期，原件版本与指纹保留；这不是仓库截至日可用库存视图。GL金额仍归实际entry_date。");metadata.put("lossBasis","原F5=D5*0.5%，G5=G4+D5-E5-F5；有限乘积完整保留，不按旧实现逐笔截成3位。实际反向按真实日期及有符号重量独立反向。");metadata.put("basis",ledger.basis());metadata.put("dateFrom",from);metadata.put("dateTo",to);
        metadata.putAll(side);return new Projection(rows,columns,s.exactMap(metadata));
    }
    private ReportTableResponse present(Projection projection,String keyword,int page,int size,FinanceReportColumnOptions options){
        var rows=projection.rows();var columns=projection.columns();var projected=new ArrayList<>(columns);
        for(var c:List.of(new ReportColumn("__ordinal","","int",1),ReportColumn.text("__rowKey",""),ReportColumn.text("__materialContextId",""),ReportColumn.text("__sourceType",""),ReportColumn.text("__sourceId",""),ReportColumn.text("__effectId",""),ReportColumn.text("__sourceFingerprint",""),ReportColumn.text("__rowKind",""),ReportColumn.text("__flowRole",""),ReportColumn.text("__notApplicable",""),ReportColumn.text("__basis",""),ReportColumn.bool("__pending",""),ReportColumn.text("__billNo","")))projected.add(c);
        for(String key:List.of("inWeight","outWeight","loss","outQty","processAmount"))projected.add(ReportColumn.number("__sum_"+key,""));
        var declarations=new ArrayList<String>();for(var c:projected)declarations.add("\""+c.key()+"\" "+(Set.of("number","money","int").contains(c.type())?"numeric":c.type().equals("bool")?"boolean":"text"));
        String sql="SELECT * FROM jsonb_to_recordset(CAST(:materialProjection AS jsonb)) AS original("+String.join(",",declarations)+")";
        var terms=KeywordSearch.terms(keyword);for(int i=0;i<terms.size();i++)sql+=(i==0?" WHERE ":" AND ")+"(\"goodsName\" ILIKE :materialKw"+i+" ESCAPE '\\' OR spec ILIKE :materialKw"+i+" ESCAPE '\\' OR \"__billNo\" ILIKE :materialKw"+i+" ESCAPE '\\')";
        String encoded=s.encode(rows);var totals=FinanceProjectedReportTable.totalSpecs(columns,projected).stream().map(t->new ReportTotalsCalculator.Spec("__sum_"+t.key(),t.label(),t.type(),t.groupKey(),t.groupIdentityKey(),true)).toList();
        var table=FinanceProjectedReportTable.query(em,projected,sql,q->{q.setParameter("materialProjection",encoded);for(int i=0;i<terms.size();i++)q.setParameter("materialKw"+i,KeywordSearch.containsPattern(terms.get(i)));},"report.\"__ordinal\"",options.filters(),Set.of(),page,size,options.sort(),options.order(),true,totals);
        var actualTotals=table.totals().stream().map(t->new ReportTotal(t.key().substring("__sum_".length()),t.label(),t.type(),t.groupKey(),t.groups(),projection.columns().stream().filter(c->c.key().equals(t.key().substring("__sum_".length()))).findFirst().map(ReportColumn::unitLabel).orElse(null))).toList();
        return new ReportTableResponse(table.columns(),table.rows(),table.facets(),table.page(),table.size(),table.total(),table.totalPages(),actualTotals,table.readScopeVersion(),table.statisticsGeneratedAt(),table.columnSearchKeys(),projection.metadata());
    }

    private record Timeline(List<Map<String,Object>> rows,BigDecimal closing,String fingerprint){}
    private Timeline timeline(Map<String,Object> c,ContextInput config,List<Map<String,Object>> evidence,ReadScope scope,List<Map<String,Object>> gl,Map<String,Map<String,Object>> fees,Map<UUID,Boolean> feeProof,boolean complete,UUID displayCurrency,LocalDate from,LocalDate to){
        UUID id=(UUID)c.get("id");var opening=s.reviewed(id,EvidenceKind.OPENING,id.toString(),scope);OpeningEvidence start=opening==null?null:s.input(opening,OpeningEvidence.class);
        boolean openingValid=opening!=null&&valid(opening,scope);LocalDate baseline=start==null?config.effectiveFrom():start.effectiveFrom();
        var facts=new LinkedHashMap<Key,Fact>();var linkedKinds=EnumSet.noneOf(Kind.class);
        for(var e:evidence)if(e.get("kind").equals("NATIVE_PARTY")&&valid(e,scope)){
            var link=s.input(e,NativePartyLink.class);if(!link.enabled())continue;linkedKinds.add(link.sourceKind());if(baseline.isAfter(to))continue;
            for(var rule:s.sourceGoods(id,scope))if(rule.sourceKind()==link.sourceKind())for(int p=1;;p++){
                var result=s.physical.candidates(new Query(link.sourceKind(),link.nativeRole().equals("SUPPLIER")?link.nativePartyId():null,link.nativeRole().equals("CUSTOMER")?link.nativePartyId():null,rule.goodsId(),rule.colorId(),baseline,to,null,p,200,rule.colorId()==null?ColorMode.NO_COLOR:ColorMode.EXACT,false));
                for(var fact:result.items()){facts.put(fact.key(),fact);}if(facts.size()>MAX)throw invalid("实际物理来源超20000行，请缩小原表范围");if(p>=result.totalPages())break;
            }
        }
        for(var e:evidence)if(e.get("kind").equals("SOURCE_RELATION")&&valid(e,scope)){var relation=s.input(e,SourceRelation.class);if(!relation.active())continue;var fact=scope.facts.computeIfAbsent(relation.source(),s::one);facts.put(fact.key(),fact);}
        scope.facts.putAll(facts);s.preloadRoutes(facts.keySet(),scope);
        var coverage=new ArrayList<SourceCoverage>();
        for(var e:evidence)if(e.get("kind").equals("COVERAGE")&&valid(e,scope)){
            var range=s.input(e,SourceCoverage.class);if(!range.active())continue;coverage.add(range);var keys=range.completeSources().stream().filter(k->!scope.facts.containsKey(k)).toList();readFacts(keys,scope);
            for(var key:range.completeSources()){var f=scope.facts.get(key);if(f!=null)facts.put(key,f);}
        }
        s.preloadRoutes(facts.keySet(),scope);
        boolean routesComplete=!from.isBefore(baseline);
        for(var kind:config.requiredSourceKinds()){
            if(s.sourceGoods(id,scope).stream().noneMatch(rule->rule.sourceKind()==kind)){routesComplete=false;continue;}
            boolean nativeComplete=linkedKinds.contains(kind);
            if(!baseline.isAfter(to)){
                var all=s.physicalScope(c,kind,baseline,to,scope);
                if(all.values().stream().anyMatch(f->scope.invalidRoutes.contains(f.key())||(f.supplierId()==null&&f.customerId()==null||f.supplierId()!=null&&f.customerId()!=null)&&!scope.routes.containsKey(f.key())))nativeComplete=false;
            }
            if(!nativeComplete&&!covered(coverage,kind,baseline,to))routesComplete=false;
        }
        var events=new ArrayList<Map<String,Object>>();var sourceFingerprint=new ArrayList<Object>();
        for(var fact:facts.values()){
            if(!s.owns(id,fact,scope))continue;var original=new TreeMap<>(fact.sourceSnapshot());original.remove("currentStatus");original.remove("originalEffects");sourceFingerprint.add(original);
            for(var effect:fact.effects()){
                if(effect.businessDate().isBefore(baseline)||effect.businessDate().isAfter(to))continue;
                if(!fact.identityComplete()){routesComplete=false;}var rule=s.sourceRule(c,fact,scope);sourceFingerprint.add(effect.sourceSnapshot());boolean incoming=rule.flowRole()==FlowRole.INBOUND,finished=rule.flowRole()==FlowRole.FINISHED_OUT;var values=quantities(id,fact,effect,scope,finished);
                BigDecimal weight=values[0]==null?null:values[0].multiply(BigDecimal.valueOf(effect.eventSign()));BigDecimal pcs=values[1]==null?null:values[1].multiply(BigDecimal.valueOf(effect.eventSign()));
                String displayName=rule.productNameCaption()==null?fact.goodsName():rule.productNameCaption(),displaySpec=rule.specificationCaption()==null?fact.specification():rule.specificationCaption();
                var row=row(id,effect.businessDate(),displayName,Objects.toString(displaySpec,""),"PHYSICAL",fact.billNo());row.put("__namePending",rule.productNameCaption()==null);row.put("inWeight",incoming?weight:BigDecimal.ZERO);row.put("outWeight",incoming?BigDecimal.ZERO:weight);row.put("loss",incoming&&weight!=null?FinancialExactAmount.book(BusinessPrecisionContext.limit(weight.multiply(new BigDecimal(".005")),"finance.material.lossWeight","本次0.5%损耗KG",30),"损耗KG"):incoming?null:BigDecimal.ZERO);row.put("outQty",finished?pcs:null);row.put("processAmount",finished?null:null);
                var notApplicable=new LinkedHashSet<String>();if(incoming){notApplicable.addAll(List.of("outWeight","outQty","price","processAmount"));}else{notApplicable.addAll(List.of("inWeight","loss"));if(!finished)notApplicable.addAll(List.of("outQty","price","processAmount"));}
                for(String field:notApplicable){row.put(field,null);}row.put("__notApplicable",String.join(",",notApplicable));row.put("__flowRole",rule.flowRole());
                row.put("__sourceType",fact.key().kind().name());row.put("__sourceId",fact.key().lineId());row.put("__effectId",effect.movementId());row.put("__sourceFingerprint",effect.identityFingerprint());row.put("__basis",fact.weightBasis()+"；原单"+fact.billNo()+"；"+String.join("；",fact.issues()));boolean zero=finished&&zeroProcessing(id,fact,effect,scope);if(zero){row.put("price",BigDecimal.ZERO);row.put("processAmount",BigDecimal.ZERO);row.put("__adjustedProcessing",BigDecimal.ZERO);row.put("__hasAdjustedProcessing",true);row.put("__quoted",true);}row.put("__pending",!fact.identityComplete()||weight==null||finished&&pcs==null||finished&&!zero||rule.productNameCaption()==null);events.add(row);
            }
        }
        // Monetary changes follow real GL dates; ordinary receipt credits and their
        // cancellation are zero root-debit occurrence, never negative processing.
        for(var g:gl){BigDecimal occurrence=decimal(g.get("occurrence"));if(occurrence==null||occurrence.signum()==0)continue;var e=fees.get(g.get("root_id")+":"+g.get("allocation_no"));if(e==null||!Boolean.TRUE.equals(feeProof.get(e.get("id"))))continue;
            var assignment=s.input(e,FeeAssignment.class);BigDecimal entryAmount=decimal(g.get("entry_amount"));if(entryAmount==null||entryAmount.signum()==0)continue;int sign=occurrence.compareTo(entryAmount)==0?1:occurrence.compareTo(entryAmount.negate())==0?-1:0;if(sign==0)throw invalid("原GL反向发生证明与实际原金额不一致，不能计算加工调整");
            var root=scope.gl.get(assignment.source());boolean exact=root!=null&&sameAmount(g.get("amount_local"),root.get("amount_local"))&&sameAmount(g.get("amount_original"),root.get("amount_original"))&&Objects.equals(g.get("original_currency_id"),root.get("original_currency_id"));
            int partIndex=0;for(var part:assignment.processingParts()){partIndex++;if(!id.equals(part.contextId()))continue;if(config.amountBasis()==AmountBasis.ORIGINAL&&g.get("original_currency_id")!=null&&g.get("amount_original")!=null&&!Objects.equals(config.originalCurrencyId(),g.get("original_currency_id")))continue;var f=scope.facts.get(part.outboundSource());if(f==null)continue;var effect=FinanceMaterialStatementService.effect(f,part.outboundMovementId());LocalDate date=date(g.get("event_date"));
                BigDecimal money=config.amountBasis()==AmountBasis.LOCAL?part.amountLocal():Objects.equals(config.originalCurrencyId(),g.get("original_currency_id"))?part.amountOriginal():null;if(!exact){money=null;}if(money!=null)money=money.multiply(BigDecimal.valueOf(sign));
                Map<String,Object> target=null;if(sign==1&&date.equals(effect.businessDate()))for(var candidate:events)if(Objects.equals(candidate.get("__effectId"),effect.movementId())){target=candidate;break;}
                if(target==null){var naming=s.sourceRule(c,f,scope);target=row(id,date,naming.productNameCaption()==null?f.goodsName():naming.productNameCaption(),Objects.toString(naming.specificationCaption()==null?f.specification():naming.specificationCaption(),""),"FEE_ADJUSTMENT",Objects.toString(g.get("voucher_no"),""));target.put("inWeight",BigDecimal.ZERO);target.put("outWeight",BigDecimal.ZERO);target.put("loss",BigDecimal.ZERO);target.put("outQty",BigDecimal.ZERO);target.put("processAmount",complete?BigDecimal.ZERO:null);target.put("__effectId",g.get("event_entry_id")+":"+g.get("allocation_no")+":"+partIndex);events.add(target);}
                BigDecimal adjusted=part.adjustmentReviewed()?money:null;
                if(adjusted!=null)for(var extra:part.adjustments()==null?List.<AdjustmentPart>of():part.adjustments()){
                    var source=assignment.adjustmentSources().stream().filter(v->v.source().equals(extra.source())).findFirst().orElse(null);
                    if(source==null||!scope.adjustmentEffects.computeIfAbsent(extra.source()+":"+g.get("voucher_id")+":"+sign,ignored->new FinanceMaterialProcessingAdjustment(s).effectProven(source,root,(UUID)g.get("voucher_id"),sign))){adjusted=null;break;}
                    if(!extra.includedInProcessing()){BigDecimal add=config.amountBasis()==AmountBasis.LOCAL?extra.amountLocal():extra.amountOriginal();if(add==null){adjusted=null;break;}adjusted=adjusted.add(add.multiply(BigDecimal.valueOf(sign)));}
                }
                BigDecimal oldAdjusted=decimal(target.get("__adjustedProcessing"));boolean firstAdjusted=!Boolean.TRUE.equals(target.get("__hasAdjustedProcessing"));target.put("__adjustedProcessing",firstAdjusted?adjusted:oldAdjusted==null||adjusted==null?null:oldAdjusted.add(adjusted));target.put("__hasAdjustedProcessing",true);
                BigDecimal old=decimal(target.get("processAmount"));boolean first=!Boolean.TRUE.equals(target.get("__hasProcessing"));target.put("processAmount",first?money:old==null||money==null?null:old.add(money));target.put("__hasProcessing",true);
                var quote=Objects.equals(displayCurrency,part.quotationCurrencyId())?part.quotedProcessingPrice():null;Object previous=target.get("price");if(!Boolean.TRUE.equals(target.get("__quoted"))){target.put("price",quote);target.put("__quoted",true);}else if(!sameAmount(previous,quote)){target.put("price",null);target.put("__quoteConflict",true);}if(Boolean.TRUE.equals(target.get("__quoteConflict")))target.put("price",null);
                target.put("__pending",Boolean.TRUE.equals(target.get("__namePending"))||money==null||quote==null||"PHYSICAL".equals(target.get("__rowKind"))&&(target.get("outWeight")==null||target.get("outQty")==null));target.put("__basis","同一真实GL allocation的受审加工份额；金融补记/反向仅在实际GL日期影响加工款，不重复实物数量");sourceFingerprint.add(List.of(e.get("id"),Objects.toString(e.get("source_fingerprint"),"")));
            }
        }
        for(var event:events)if("PHYSICAL".equals(event.get("__rowKind"))&&Boolean.TRUE.equals(event.get("__hasProcessing"))){
            BigDecimal quote=decimal(event.get("price")),quantity=decimal(event.get("outQty")),money=decimal(event.get("processAmount"));
            if(quote==null){event.put("__pending",true);event.put("__basis",event.get("__basis")+"；原I列单价尚不能证明为同一纸面币别的唯一报价");}
            else if(quantity!=null&&money!=null&&quantity.multiply(quote).compareTo(money)!=0){event.put("__pending",true);event.put("__basis",event.get("__basis")+"；实际PCS×明确报价与真实AR加工份额不同，请核对原折让/调账或报价口径；J仍保留真实GL份额，不按报价改写账款");}
        }
        events.sort(Comparator.comparing((Map<String,Object> m)->date(m.get("billDate"))).thenComparing(m->Objects.toString(m.get("__billNo"),"")).thenComparing(m->Objects.toString(m.get("__effectId"),"")));
        BigDecimal balance=openingValid&&routesComplete&&start!=null&&!from.isBefore(baseline)?start.balanceWeightKg():null;
        var output=new ArrayList<Map<String,Object>>();String name=config.productNameCaption(),spec=Objects.toString(config.specificationCaption(),"");
        boolean added=false;for(var row:events){LocalDate date=date(row.get("billDate"));if(!date.isBefore(from)&&!added){output.add(openingRow(id,from,name,spec,balance,complete,routesComplete));added=true;}
            BigDecimal in=applicable(row,"inWeight"),out=applicable(row,"outWeight"),loss=applicable(row,"loss");balance=balance==null||in==null||out==null||loss==null?null:FinancialExactAmount.book(balance.add(in).subtract(out).subtract(loss),"滚动结余KG");row.put("balance",balance);if(balance==null){row.put("__pending",true);}if(!date.isBefore(from))output.add(row);
        }
        if(!added)output.add(openingRow(id,from,name,spec,balance,complete,routesComplete));
        var subtotal=row(id,to,"","","SUBTOTAL","");subtotal.put("billDate","合计");
        for(String key:List.of("inWeight","outWeight","loss","outQty","processAmount"))subtotal.put(key,sum(output,key));
        if(!routesComplete)for(String key:List.of("inWeight","outWeight","loss","outQty"))subtotal.put(key,null);
        if(!complete){subtotal.put("processAmount",null);}subtotal.put("balance",balance);subtotal.put("__basis","本材料完整原表范围的实际发生合计；结余取最后已核余额，不对滚动结余列求和");subtotal.put("__pending",balance==null||!complete||!routesComplete);output.add(subtotal);
        subtotal.put("__adjustedProcessing",complete?sumAdjusted(output):null);
        sourceFingerprint.add(output);return new Timeline(output,balance,s.hash(sourceFingerprint));
    }
    private boolean zeroProcessing(UUID context,Fact fact,Effect effect,ReadScope scope){
        var original=effect.reversal()?fact.effects().stream().filter(e->!e.reversal()&&e.eventSign()>0).toList():List.of(effect);if(original.isEmpty())return false;
        for(var source:original){var evidence=s.reviewed(context,EvidenceKind.ZERO,context+":"+source.movementId(),scope);if(evidence==null||!s.input(evidence,ZeroProcessing.class).zeroProcessing()||!valid(evidence,scope))return false;}return true;
    }
    private BigDecimal[] quantities(UUID contextId,Fact fact,Effect effect,ReadScope scope,boolean finished){
        var measured=s.reviewed(contextId,EvidenceKind.WEIGHT,contextId+":"+effect.movementId(),scope);WeightEvidence w=measured!=null&&valid(measured,scope)?s.input(measured,WeightEvidence.class):null;if(w!=null&&!w.active())w=null;
        var conversions=new ArrayList<UnitEvidence>();
        if(effect.unitId()!=null){
            var specific=s.reviewed(contextId,EvidenceKind.UNIT,unitKey(contextId,fact.goodsId(),fact.colorId(),effect.unitId(),"SOURCE",effect.unitRate()),scope);
            var basic=s.reviewed(contextId,EvidenceKind.UNIT,unitKey(contextId,fact.goodsId(),fact.colorId(),effect.unitId(),"BASE",null),scope);
            for(var evidence:Arrays.asList(specific,basic))if(evidence!=null&&valid(evidence,scope)){var conversion=s.input(evidence,UnitEvidence.class);if(conversion.active())conversions.add(conversion);}
        }
        BigDecimal kg=effect.weightKg()!=null?effect.weightKg():w==null?null:w.actualWeightKg(),pcs=!finished?null:w==null?null:w.actualQuantityPcs();
        for(var conversion:conversions){BigDecimal denominator=conversion.quantityBasis().equals("BASE")?BigDecimal.ONE:effect.unitRate();
            if(kg==null&&conversion.kgPerSourceUnit()!=null&&"EXACT_UNIT".equals(conversion.kgBasis())&&effect.baseQuantity()!=null&&denominator!=null)
                kg=FinancialExactAmount.book(BusinessPrecisionContext.divide(effect.baseQuantity().multiply(conversion.kgPerSourceUnit()),denominator,"finance.material.kgConversion","本次材料KG换算",30),"已核KG换算");
            if(finished&&pcs==null&&conversion.pcsPerSourceUnit()!=null&&effect.baseQuantity()!=null&&denominator!=null)
                pcs=FinancialExactAmount.book(BusinessPrecisionContext.divide(effect.baseQuantity().multiply(conversion.pcsPerSourceUnit()),denominator,"finance.material.pcsConversion","本次材料PCS换算",30),"已核PCS换算");
        }
        if(!fact.identityComplete()){kg=null;pcs=null;}return new BigDecimal[]{kg,pcs};
    }
    private boolean valid(Map<String,Object> e,ReadScope scope){return scope.valid.computeIfAbsent((UUID)e.get("id"),ignored->{try{return s.validate(e,false,scope).fingerprint().equals(e.get("source_fingerprint"));}catch(com.uten.imp.common.web.ApiException error){return false;}});}
    private static boolean covered(List<SourceCoverage> evidence,Kind kind,LocalDate from,LocalDate to){
        if(from.isAfter(to))return false;LocalDate next=from;for(var range:evidence.stream().filter(e->e.sourceKind()==kind).sorted(Comparator.comparing(SourceCoverage::dateFrom)).toList()){
            if(range.dateFrom().isAfter(next))continue;if(!range.dateTo().isBefore(next)){next=range.dateTo().plusDays(1);}if(next.isAfter(to))return true;
        }return false;
    }
    private void readFacts(List<Key> keys,ReadScope scope){for(int offset=0;offset<keys.size();offset+=200)for(var f:s.physical.readForIdentity(keys.subList(offset,Math.min(keys.size(),offset+200))))scope.facts.put(f.key(),f);}
    private List<Map<String,Object>> glFacts(String account,UUID aux,UUID currency,LocalDate from,LocalDate to){
        var rows=s.db.queryForList("""
            SELECT a.*,e.id event_entry_id,e.amount entry_amount,e.entry_date event_date,e.voucher_id,v.voucher_no,
              fn_finance_debit_occurrence(e.id) occurrence,origin.id root_id
            FROM finance_gl_entry_allocations a JOIN gl_entries e ON e.id=a.entry_id JOIN gl_vouchers v ON v.id=e.voucher_id
            LEFT JOIN LATERAL(
              WITH RECURSIVE chain AS(SELECT e.id,e.voucher_id,e.line_no,e.style_id,0 depth
                UNION ALL SELECT parent.id,parent.voucher_id,parent.line_no,parent.style_id,chain.depth+1 FROM chain
                JOIN gl_vouchers current_voucher ON current_voucher.id=chain.voucher_id
                JOIN gl_entries parent ON parent.voucher_id=current_voucher.reversal_of_voucher_id AND parent.line_no=chain.line_no AND parent.style_id=chain.style_id AND NOT parent.is_deleted
                WHERE chain.depth<17)
              SELECT id FROM chain ORDER BY depth DESC LIMIT 1
            )origin ON true
            WHERE a.account_code=? AND a.auxiliary_id=? AND a.currency_id=? AND e.entry_date BETWEEN ? AND ?
              AND NOT e.is_deleted AND fn_finance_gl_voucher_is_booked(v.id) AND NOT fn_finance_entry_is_pnl_closing(e.id)
            ORDER BY e.entry_date,e.id,a.allocation_no LIMIT 20001
            """,account,aux,currency,from,to);
        if(rows.size()>MAX)throw invalid("本期真实GL来源超20000条，请按会计期间分段核对");return rows;
    }
    private void loadRoots(Set<UUID> roots,String account,UUID aux,UUID currency,FinancialAuxiliaryValidationPort.Ref ref,ReadScope scope){
        var ids=new ArrayList<>(roots);for(int offset=0;offset<ids.size();offset+=200){var chunk=ids.subList(offset,Math.min(offset+200,ids.size()));var params=new ArrayList<Object>(chunk);params.add(account);params.add(aux);params.add(currency);
            for(var row:s.db.queryForList("SELECT a.*,e.direction,e.entry_date,e.style_id,e.voucher_id,v.voucher_no FROM finance_gl_entry_allocations a JOIN gl_entries e ON e.id=a.entry_id JOIN gl_vouchers v ON v.id=e.voucher_id WHERE e.id IN("+String.join(",",Collections.nCopies(chunk.size(),"?"))+") AND a.account_code=? AND a.auxiliary_id=? AND a.currency_id=? AND NOT e.is_deleted AND fn_finance_gl_voucher_is_booked(v.id)",params.toArray())){
                if(((Number)row.get("direction")).intValue()!=1||!Objects.equals(row.get("party_id_snapshot"),ref.partyId())||!Objects.equals(row.get("auxiliary_role"),ref.role()))continue;
                var stable=new TreeMap<String,Object>();for(String field:List.of("entry_id","allocation_no","account_code","auxiliary_id","currency_id","original_currency_id","amount_local","amount_original","entry_date","direction","style_id","voucher_id","voucher_no","party_id_snapshot","auxiliary_role"))stable.put(field,row.get(field));
                scope.gl.put(new GlAllocationKey((UUID)row.get("entry_id"),((Number)row.get("allocation_no")).intValue()),stable);
            }
        }
    }
    private UUID baseCurrency(){var ids=s.db.queryForList("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted",UUID.class);if(ids.size()!=1)throw invalid("本位币单位尚未唯一明确，不能将会计属性币别冒作本位币");return ids.getFirst();}
    private static List<ReportColumn> columns(String currency){var columns=new ArrayList<>(FinanceStatementTemplate.columns("other-receivable"));columns.set(0,ReportColumn.text("billDate",columns.getFirst().label(),165).withHeaderGroups(columns.getFirst().headerGroups()));
        for(int i=0;i<columns.size();i++){var c=columns.get(i);if(Set.of("inWeight","outWeight","loss").contains(c.key())){c=c.withUnitLabel("KG").totaled(c.label());}if(c.key().equals("outQty")){c=c.withUnitLabel("PCS").totaled(c.label());}if(c.key().equals("processAmount")){c=c.withUnitLabel(currency).totaled(c.label());}if(c.key().equals("price")){c=c.withUnitLabel(currency);}columns.set(i,c);}return List.copyOf(columns);}
    private static Map<String,Object> row(UUID context,LocalDate date,String name,String spec,String kind,String bill){var r=new LinkedHashMap<String,Object>();r.put("billDate",date.toString());r.put("goodsName",name);r.put("spec",spec);r.put("price",null);r.put("__materialContextId",context);r.put("__rowKind",kind);r.put("__billNo",bill);r.put("__pending",false);return r;}
    private static Map<String,Object> openingRow(UUID context,LocalDate from,String name,String spec,BigDecimal amount,boolean money,boolean routes){var r=row(context,from,name,spec,"OPENING","");r.put("billDate",from+"期初结余");r.put("inWeight",BigDecimal.ZERO);r.put("outWeight",BigDecimal.ZERO);r.put("loss",BigDecimal.ZERO);r.put("balance",amount);r.put("outQty",BigDecimal.ZERO);r.put("processAmount",money?BigDecimal.ZERO:null);r.put("__pending",amount==null||!money);r.put("__materialCoverageComplete",routes);r.put("__processingCoverageComplete",money);r.put("__notApplicable","inWeight,outWeight,loss,outQty,price,processAmount");for(String field:List.of("inWeight","outWeight","loss","outQty","price","processAmount")){r.put(field,null);}r.put("__basis",routes?"已核期初KG加实际发生滚动；缺称重后续结余保持未知":"原来料/出料关系尚未完整，不能将未归户来源当0");return r;}
    private static BigDecimal sumAdjusted(List<Map<String,Object>> rows){BigDecimal total=BigDecimal.ZERO;for(var row:rows){if("SUBTOTAL".equals(row.get("__rowKind")))continue;if(Arrays.asList(Objects.toString(row.get("__notApplicable"),"").split(",")).contains("processAmount"))continue;BigDecimal v=decimal(row.get("__adjustedProcessing"));if(v==null)return null;total=total.add(v);}return total;}
    private Map<String,Object> sideTables(Map<UUID,ContextInput> configs,List<Map<String,Object>> rows,boolean complete,Map<Integer,Map<String,Object>> sidebar){
        var cells=new ArrayList<Map<String,Object>>();String[] heads={"名称","单位","数量","单价","金额"};
        for(int sourceRow:List.of(4,12))for(int col=0;col<5;col++)cell(cells,Character.toString((char)('L'+col))+sourceRow,heads[col],"text",true,false,"财务原隐藏区原头");
        var subtotals=new HashMap<UUID,Map<String,Object>>();for(var row:rows)if("SUBTOTAL".equals(row.get("__rowKind")))subtotals.put((UUID)row.get("__materialContextId"),row);
        BigDecimal adjusted=BigDecimal.ZERO;boolean adjustedKnown=complete;for(var subtotal:subtotals.values()){var amount=decimal(subtotal.get("__adjustedProcessing"));if(amount==null)adjustedKnown=false;else adjusted=adjusted.add(amount);}
        var legacy=new HashMap<Integer,UUID>();for(var config:configs.entrySet())if(config.getValue().sideSlot()!=null&&!sidebar.containsKey(config.getValue().sideSlot())){if(legacy.putIfAbsent(config.getValue().sideSlot(),config.getKey())!=null)throw invalid("同一原旁算位置对应多个材料组，请维护确切旁算资料");}
        BigDecimal sideProcessing=BigDecimal.ZERO,sideAdjusted=BigDecimal.ZERO;boolean sideProcessingKnown=true,sideAdjustedKnown=true;
        for(int slot=1;slot<=4;slot++){
            var evidence=sidebar.get(slot);var line=evidence==null?null:s.input(evidence,SidebarLine.class);boolean referenceValid=evidence==null||Boolean.TRUE.equals(evidence.get("__valid"));UUID bound=line==null?legacy.get(slot):line.materialContextId();
            var subtotal=referenceValid&&bound!=null?subtotals.get(bound):null;BigDecimal qty=subtotal==null?null:decimal(subtotal.get("outQty")),actual=subtotal==null?null:decimal(subtotal.get("processAmount")),extra=subtotal==null?null:decimal(subtotal.get("__adjustedProcessing"));
            var matching=bound==null?List.<Map<String,Object>>of():rows.stream().filter(row->bound.equals(row.get("__materialContextId"))&&Boolean.TRUE.equals(row.get("__hasProcessing"))).toList();
            var quotes=matching.stream().map(row->decimal(row.get("price"))).toList();BigDecimal actualPrice=!quotes.isEmpty()&&quotes.getFirst()!=null&&quotes.stream().allMatch(value->value!=null&&value.compareTo(quotes.getFirst())==0)?quotes.getFirst():null;
            BigDecimal shownPrice=actualPrice!=null?actualPrice:line==null?null:line.referencePrice();boolean referencePrice=shownPrice!=null&&actualPrice==null;
            String name=line==null?null:line.productNameCaption();if(name==null){var names=matching.stream().filter(row->!Boolean.TRUE.equals(row.get("__namePending"))).map(row->Objects.toString(row.get("goodsName"),"")).filter(value->!value.isBlank()).distinct().toList();if(names.size()==1)name=names.getFirst();}
            BigDecimal quoted=qty==null||actualPrice==null?null:BusinessPrecisionContext.limit(qty.multiply(actualPrice),"finance.material.quotedProcessingAmount","原隐藏区实际PCS乘实际已核报价金额",30);
            boolean pricingPending=quoted==null||actual==null||quoted.compareTo(actual)!=0;if(quoted==null){sideProcessingKnown=false;}else{sideProcessing=sideProcessing.add(quoted);}if(extra==null)sideAdjustedKnown=false;else sideAdjusted=sideAdjusted.add(extra);
            BigDecimal adjustedPrice=extra==null||qty==null||qty.signum()==0?null:BusinessPrecisionContext.divide(extra,qty,"finance.material.adjustedUnitPrice","本次调整后实际加工单价",30);
            int top=4+slot,bottom=12+slot;for(int at:List.of(top,bottom)){cell(cells,"L"+at,name,"text",false,name==null||!referenceValid,"原旁算该型号受审名称，不从原料组名猜成品名");cell(cells,"M"+at,line==null&&bound==null?null:"PCS","text",false,line==null&&bound==null,"原单位文字，仅引用真实PCS");cell(cells,"N"+at,qty,"number",false,qty==null,"仅来自明确绑定的本次主表真实H合计；未绑定不填0");}
            cell(cells,"O"+top,shownPrice,"money",false,shownPrice==null||referencePrice||!referenceValid,referencePrice?"原文件本型号/有效期间的受审参考报价，不能冒作实际金额或所有商品/月默认价":"原真实GL加工归属中的同币别唯一实际报价");
            cell(cells,"P"+top,quoted,"money",false,pricingPending,"原式N×O只取真实PCS及实际已核报价；参考价不生成P，差异与真实J独立保留待核");cell(cells,"Q"+top,extra,"money",false,extra==null,"同一真实GL已审调整额，已含入J不重加，不除0.87");cell(cells,"O"+bottom,adjustedPrice,"money",false,adjustedPrice==null,"真实调整额除真实PCS；非有限按本次精度选择");cell(cells,"P"+bottom,extra,"money",false,extra==null,"同原Q位置实际调整额");
        }
        cell(cells,"P9",sideProcessingKnown?sideProcessing:null,"money",false,!sideProcessingKnown,"原四个P位置之和，不把未映射材料塞进这四行");cell(cells,"Q9",sideAdjustedKnown?sideAdjusted:null,"money",false,!sideAdjustedKnown,"原四个Q位置之和");cell(cells,"P17",sideAdjustedKnown?sideAdjusted:null,"money",false,!sideAdjustedKnown,"同原Q9");
        var result=new LinkedHashMap<String,Object>();result.put("supplementalCells",cells);result.put("processingAdjustedTotal",adjustedKnown?adjusted:null);result.put("processingAdjustmentBasis","主表所有真实材料组的已审GL调整额；独立旁算参考名称/报价不改变主表组、物量、GL或总额，缺来源不填0。");return result;
    }
    private static void cell(List<Map<String,Object>> cells,String coordinate,Object value,String type,boolean header,boolean pending,String basis){var cell=new LinkedHashMap<String,Object>();cell.put("sourceCell",coordinate);cell.put("value",value instanceof BigDecimal n?n.toPlainString():value);cell.put("type",type);cell.put("header",header);cell.put("pending",pending);cell.put("basis",basis);cells.add(cell);}
    private static BigDecimal applicable(Map<String,Object> row,String key){return Arrays.asList(Objects.toString(row.get("__notApplicable"),"").split(",")).contains(key)?BigDecimal.ZERO:decimal(row.get(key));}
    private static BigDecimal sum(List<Map<String,Object>> rows,String key){BigDecimal total=BigDecimal.ZERO;for(var row:rows){BigDecimal v=applicable(row,key);if(v==null)return null;total=total.add(v);}return total;}
    private static boolean sameAmount(Object a,Object b){return a==null?b==null:b!=null&&decimal(a).compareTo(decimal(b))==0;}
    private static LocalDate date(Object v){return v instanceof LocalDate d?d:v instanceof java.sql.Date d?d.toLocalDate():LocalDate.parse(v.toString());}
}
