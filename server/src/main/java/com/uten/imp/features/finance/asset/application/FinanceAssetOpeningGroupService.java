package com.uten.imp.features.finance.asset.application;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.features.finance.asset.domain.StraightLineScheduleCalculator;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.asset.api.AssetOpeningGroupContracts.*;
import com.uten.imp.features.finance.FinanceCompanyReportAccess;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.security.CurrentAuthorityGuard;
import com.uten.imp.features.finance.report.FinanceTemplateSourceReader;
import com.uten.imp.features.finance.report.FinanceTemplateSourceService;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.math.*;
import java.nio.charset.StandardCharsets;
import java.time.*;
import java.util.*;

/** Group-level recognition of already posted opening entries. This service never writes GL. */
@Service @RequiredArgsConstructor
public class FinanceAssetOpeningGroupService {
    @org.springframework.beans.factory.annotation.Autowired
    private com.uten.imp.common.readsnapshot.VersionedSummaryPages summaryPages;

    private final JdbcTemplate db;private final ObjectMapper json;private final TxSessionVars tx;
    private final FinanceAssetAuthorization auth;private final FinanceTemplateSourceService sources;
    private final FinanceAssetTemplateService metadata;
    private final FinanceDocumentAccessPolicy companyAccess;

    @Transactional(readOnly=true)
    public Map<String,Object> list(){auth.require(FinanceAssetAuthorization.VIEW);return Map.of("items",db.queryForList("SELECT id,as_of,source_voucher_id,status,row_version AS version,created_at,reason FROM finance_asset_opening_groups ORDER BY created_at DESC,id DESC LIMIT 100"));}
    @Transactional(readOnly=true)
    public Map<String,Object> get(UUID id){auth.require(FinanceAssetAuthorization.VIEW);return group(id,false);}
    /** Only the immutable source already bound to this authorised group is shared with its reviewer. */
    @Transactional(readOnly=true)
    public FinanceTemplateSourceReader.Preview source(UUID id){
        auth.require(FinanceAssetAuthorization.VIEW);
        var rows=db.queryForList("SELECT s.preview::text FROM finance_asset_opening_groups g JOIN finance_template_sources s ON s.id=g.source_import_id WHERE g.id=?",String.class,id);
        if(rows.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"接续组不存在或原来源未完整保存");
        try{return json.readValue(rows.getFirst(),FinanceTemplateSourceReader.Preview.class);}
        catch(Exception e){throw new IllegalStateException("接续组冻结来源记录无效",e);}
    }
    @Transactional(readOnly=true)
    public Map<String,Object> voucher(String voucherNo){
        auth.require(FinanceAssetAuthorization.EDIT);CurrentAuthorityGuard.requireAll("finance_report:view");FinanceCompanyReportAccess.require(companyAccess);
        if(voucherNo==null||voucherNo.isBlank()||voucherNo.length()>100)throw invalid("请输入完整的原期初凭证号");
        var rows=db.queryForList("SELECT id,voucher_no AS \"voucherNo\",voucher_date AS \"voucherDate\" FROM gl_vouchers WHERE voucher_no=? AND status=1 AND NOT is_deleted ORDER BY id LIMIT 10",voucherNo.trim());
        for(var v:rows)v.put("entries",db.queryForList("SELECT e.id,e.style_id AS \"styleId\",COALESCE(chart.code,s.code) AS code,COALESCE(chart.name,s.name) AS name,e.direction,e.amount::text AS amount,claim.group_id AS \"claimedGroupId\" FROM gl_entries e LEFT JOIN payment_styles s ON s.id=e.style_id LEFT JOIN finance_chart_code_styles mapped ON mapped.style_id=s.id LEFT JOIN finance_chart_codes chart ON chart.code=mapped.code LEFT JOIN finance_asset_opening_entry_claims claim ON claim.entry_id=e.id WHERE e.voucher_id=? AND NOT e.is_deleted ORDER BY e.line_no,e.id",v.get("id")));
        return Map.of("items",rows);
    }
    @Transactional
    public Map<String,Object> create(Create input){
        UUID actor=auth.requireActorId(FinanceAssetAuthorization.EDIT);tx.bind();
        if(input==null||input.requestId()==null)throw invalid("缺少接续请求编号");lock("request:"+input.requestId());
        String fingerprint=ImmutableDocumentStore.digest(encode(input).getBytes(StandardCharsets.UTF_8));
        var previous=db.queryForList("SELECT actor_id,fingerprint FROM finance_asset_opening_groups WHERE id=?",input.requestId());
        if(!previous.isEmpty()){
            if(!actor.equals(previous.getFirst().get("actor_id"))||!fingerprint.equals(previous.getFirst().get("fingerprint")))throw conflict("原请求编号已用于其他接续内容，请先核对原结果");
            return group(input.requestId(),false);
        }
        if(input.members()==null||input.members().isEmpty()||input.members().size()>2000||input.entryIds()==null||input.entryIds().size()>2000)throw invalid("请选择完整成员及原凭证资产条目");
        if(new HashSet<>(input.entryIds()).size()!=input.entryIds().size()||input.members().stream().map(m->m.objectType()+m.objectId()).distinct().count()!=input.members().size()
                ||input.members().stream().map(Member::sourceRow).distinct().count()!=input.members().size())throw invalid("原凭证条目、原表行及资产成员不能重复");
        if(input.asOf()==null||input.asOf().isAfter(BusinessTime.today())||!YearMonth.from(input.asOf()).atEndOfMonth().equals(input.asOf()))throw invalid("接续日须为已经结束的月末");
        if(input.reason()==null||input.reason().isBlank())throw invalid("请填写本次接续核对依据");
        var source=sources.get(input.sourceImportId());
        if(!Set.of("depreciation","amortization","depreciationCompleted").contains(source.template())||!source.issues().isEmpty()||!source.hiddenIncluded())throw invalid("原表未完整核对，不能建立期初接续");
        if(!YearMonth.parse(source.period()).atEndOfMonth().equals(input.asOf()))throw invalid("接续日与所选原表会计月份不一致");
        var voucherIds=input.sourceVoucherIds()==null?(input.sourceVoucherId()==null?List.<UUID>of():List.of(input.sourceVoucherId())):input.sourceVoucherIds();
        if(voucherIds.size()>2000||voucherIds.stream().anyMatch(Objects::isNull)||input.sourceVoucherId()!=null&&!voucherIds.contains(input.sourceVoucherId())||new HashSet<>(voucherIds).size()!=voucherIds.size()
                ||!input.entryIds().isEmpty()&&(input.sourceVoucherId()==null||voucherIds.isEmpty()))throw invalid("请选择完整且不重复的来源凭证组合，并指定其中的主要凭证");
        for(UUID sourceVoucher:voucherIds.stream().sorted().toList()){
            lock("voucher:"+sourceVoucher);
            var vouchers=db.queryForList("SELECT id,voucher_date FROM gl_vouchers WHERE id=? AND status=1 AND NOT is_deleted FOR UPDATE",sourceVoucher);
            if(vouchers.size()!=1||date(vouchers.getFirst().get("voucher_date")).isAfter(input.asOf()))throw invalid("来源凭证必须已入账且不晚于接续日");
            if(db.queryForObject("SELECT count(*) FROM fixed_assets WHERE opening_voucher_id=? AND lifecycle_status<>'REVERSED' AND NOT is_deleted",Integer.class,sourceVoucher)!=0)throw conflict("来源凭证已有单资产接续认领，请先核对原认领，不能再整组重复使用");
        }
        List<Map<String,Object>> snapshots=new ArrayList<>(),histories=new ArrayList<>();Map<UUID,BigDecimal> expected=new HashMap<>();
        for(var m:input.members().stream().sorted(Comparator.comparing(x->x.objectId().toString())).toList()) {
            boolean deferred=m.objectType().equals("DEFERRED_EXPENSE");
            if(deferred!=source.template().equals("amortization"))throw invalid("固定资产、完成清单与待摊的来源不能交叉使用");
            var row=source.rows().stream().filter(r->r.sourceRow()==m.sourceRow()).findFirst().orElseThrow(()->invalid("原表数据行不存在"));
            if(!row.issues().isEmpty())throw invalid("原表第"+m.sourceRow()+"行存在错误单元格，请先核对本行："+String.join("；",row.issues()));
            var asset=asset(m,true);if(!"DRAFT".equals(asset.get("lifecycle_status")))throw invalid("整组接续先从资产/待摊草稿建立，不能覆盖已入账记录");
            if(!deferred&&asset.get("opening_voucher_id")!=null)throw conflict("成员已有单资产期初凭证关联，请明确撤销原关联后再建立整组接续");
            if(((Number)asset.get("row_version")).longValue()!=m.expectedVersion())throw conflict("成员资料已变化，请刷新核对");
            if(db.queryForObject("SELECT count(*) FROM finance_asset_opening_members WHERE object_type=? AND object_id=? AND active",Integer.class,m.objectType(),m.objectId())!=0)throw conflict("该成员已被另一组接续认领");
            lock("source-row:"+source.sha256()+":"+source.sourceSheet()+":"+m.sourceRow());
            if(db.queryForObject("SELECT count(*) FROM finance_asset_opening_members WHERE source_sha256=? AND source_sheet=? AND source_row=? AND active",Integer.class,source.sha256(),source.sourceSheet(),m.sourceRow())!=0)throw conflict("该原表行已被另一组接续认领，不能按名称另建一份");
            BigDecimal original=FinancialExactAmount.require(number(row,deferred?7:9),"原表原值/全额");
            if(original.signum()<=0||original.compareTo(decimal(asset.get("original_amount")))!=0)throw invalid("原表第"+m.sourceRow()+"行原值/全额与所选成员不一致");
            if(!text(row,deferred?3:6).equals(asset.get("name")))throw invalid("原表第"+m.sourceRow()+"行名称与所选成员不一致，请明确核对来源行");
            BigDecimal cumulative=source.template().equals("depreciationCompleted")?
                    money(original.subtract(original.multiply(decimal(asset.get("residual_rate"))))):
                    money(deferred?number(row,24):number(row,36).add(numberOrZero(row,55)));
            BigDecimal maximum=money(original.subtract(original.multiply(decimal(asset.get("residual_rate")))));
            if(cumulative.signum()<0||cumulative.compareTo(maximum)>0||(cumulative.compareTo(maximum)==0?m.remainingMonths()!=0:m.remainingMonths()<1)||m.remainingMonths()>1200)throw invalid("原表累计、残值和剩余计提月份未对应，请核对第"+m.sourceRow()+"行");
            BigDecimal sourceMonthly=money(number(row,deferred?9:11));
            if(m.remainingMonths()>0&&StraightLineScheduleCalculator.regularAmount(maximum.subtract(cumulative),m.remainingMonths()).subtract(sourceMonthly).abs().compareTo(new BigDecimal(".0001"))>0)
                throw invalid("原表第"+m.sourceRow()+"行月计提额与原值、已提累计、剩余月数不一致，请明确核对剩余期限，不能另算一套月金额");
            UUID cost=(UUID)asset.get("cost_style_id"),credit=deferred?null:(UUID)asset.get("accumulated_style_id");
            if(cost==null||(!deferred&&credit==null))throw invalid("成员须先选择财务已核对的会计政策");
            var snapshot=new LinkedHashMap<String,Object>(asset);snapshot.put("objectType",m.objectType());snapshot.put("objectId",m.objectId());snapshot.put("sourceRow",m.sourceRow());
            snapshot.put("nominalMonthly",sourceMonthly.toPlainString());snapshot.put("original",original.toPlainString());snapshot.put("accumulated",cumulative.toPlainString());snapshot.put("remainingMonths",m.remainingMonths());snapshots.add(snapshot);
            expected.merge(cost,deferred?original.subtract(cumulative):original,BigDecimal::add);if(!deferred)expected.merge(credit,cumulative.negate(),BigDecimal::add);
            histories.addAll(history(source,row,m,cumulative,input.reason()));
        }
        List<Map<String,Object>> entries=new ArrayList<>();Map<UUID,BigDecimal> actual=new HashMap<>();
        for(UUID entryId:input.entryIds().stream().sorted().toList()){
            var rows=db.queryForList("SELECT e.id,e.style_id AS \"styleId\",e.direction,e.amount::text AS amount,e.voucher_id AS \"voucherId\",v.voucher_no AS \"voucherNo\",v.voucher_date::text AS \"voucherDate\" FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id WHERE e.id=? AND NOT e.is_deleted FOR UPDATE OF e",entryId);
            if(rows.size()!=1||!voucherIds.contains(rows.getFirst().get("voucherId")))throw invalid("所选GL条目已变化或不属于本次来源凭证组合");
            if(db.queryForObject("SELECT count(*) FROM finance_asset_opening_entry_claims WHERE entry_id=?",Integer.class,entryId)!=0)throw conflict("原凭证资产条目已由另一组认领");
            var entry=rows.getFirst();entries.add(entry);actual.merge((UUID)entry.get("styleId"),decimal(entry.get("amount")).multiply(decimal(entry.get("direction"))),BigDecimal::add);
        }
        expected.entrySet().removeIf(e->e.getValue().signum()==0);actual.entrySet().removeIf(e->e.getValue().signum()==0);
        if(!same(expected,actual))throw invalid("原值/累计折旧或待摊余额按财务科目的合计与所选GL条目不一致，不能认领或重复记账");
        List<Map<String,Object>> zeroProofs=new ArrayList<>();
        if(entries.isEmpty()) {
            if(!source.template().equals("amortization")||snapshots.stream().anyMatch(s->decimal(s.get("original")).compareTo(decimal(s.get("accumulated")))!=0||((Number)s.get("remainingMonths")).intValue()!=0))throw invalid("无GL条目只适用于原额已全部摊销且有明确零余额证明的待摊记录");
            for(UUID style:snapshots.stream().map(s->(UUID)s.get("cost_style_id")).distinct().toList()){
                var proof=db.queryForMap("SELECT fn_finance_style_balance_asof(?,?) AS balance,fn_finance_style_balance_evidence_fingerprint(?,?) AS fingerprint",style,input.asOf(),style,input.asOf());
                if(!(proof.get("balance") instanceof BigDecimal amount)||amount.signum()!=0||!(proof.get("fingerprint") instanceof String evidence)||evidence.isBlank())throw invalid("该待摊成本科目没有已核对的零余额来源，不能把缺凭证当成0");
                zeroProofs.add(Map.of("styleId",style,"asOf",input.asOf().toString(),"amount","0","fingerprint",evidence));
            }
        }
        db.update("INSERT INTO finance_asset_opening_groups(id,actor_id,source_import_id,source_voucher_id,as_of,fingerprint,status,source_entry_snapshot,member_snapshot,reason,source_voucher_ids,zero_balance_evidence) VALUES(?,?,?,?,?,?,'SUBMITTED',?::jsonb,?::jsonb,?,?::uuid[],?::jsonb)",input.requestId(),actor,input.sourceImportId(),input.sourceVoucherId(),input.asOf(),fingerprint,encode(entries),encode(snapshots),input.reason(),"{"+String.join(",",voucherIds.stream().map(UUID::toString).toList())+"}",encode(zeroProofs));
        for(var snap:snapshots){boolean deferred=snap.get("objectType").equals("DEFERRED_EXPENSE");
            db.update("INSERT INTO finance_asset_opening_members(group_id,object_type,object_id,source_row,source_sha256,source_sheet,original_amount,accumulated_amount,remaining_months,cost_style_id,accumulated_style_id,nominal_monthly_amount) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",input.requestId(),snap.get("objectType"),snap.get("objectId"),snap.get("sourceRow"),source.sha256(),source.sourceSheet(),decimal(snap.get("original")),decimal(snap.get("accumulated")),snap.get("remainingMonths"),snap.get("cost_style_id"),deferred?null:snap.get("accumulated_style_id"),decimal(snap.get("nominalMonthly")));
            db.update("UPDATE "+(deferred?"deferred_expenses":"fixed_assets")+" SET opening_as_of=?,"+(deferred?"opening_amortized_amount":"opening_accumulated_amount")+"=?,opening_remaining_months=?,start_period=?,row_version=row_version+1,updated_at=now(),updated_by=? WHERE id=?",input.asOf(),decimal(snap.get("accumulated")),snap.get("remainingMonths"),YearMonth.from(input.asOf()).plusMonths(1).toString(),actor,snap.get("objectId"));
            db.update("UPDATE "+(deferred?"deferred_expenses":"fixed_assets")+" SET source_type='FINANCE_TEMPLATE',source_id=?,source_ref=?,source_line_ref=? WHERE id=?",source.importId(),source.sourceSheet()+"（"+source.period()+"）","ROW:"+snap.get("sourceRow"),snap.get("objectId"));
            event(snap.get("objectType").toString(),(UUID)snap.get("objectId"),input.requestId(),"建立旧账接续待复核",input.reason(),actor);
        }
        for(UUID entry:input.entryIds())db.update("INSERT INTO finance_asset_opening_entry_claims(entry_id,group_id) VALUES(?,?)",entry,input.requestId());
        for(var h:histories)db.update("INSERT INTO finance_asset_template_history(group_id,object_type,object_id,period_from,period_to,amount_local,reported_value,source_import_id,source_row,source_column,adjustment_reason) VALUES(?,?,?,?,?,?,?,?,?,?,?)",input.requestId(),h.get("type"),h.get("id"),h.get("from"),h.get("to"),h.get("amount"),h.get("reported"),source.importId(),h.get("row"),h.get("column"),h.get("reason"));
        for(var m:input.members())importMetadata(input,source,m);
        return group(input.requestId(),false);
    }

    @Transactional
    public Map<String,Object> approve(UUID id,Action action){
        UUID actor=auth.requireActorId(FinanceAssetAuthorization.APPROVE);tx.bind();var group=group(id,true);version(group,action);
        if(!group.get("status").equals("SUBMITTED")||actor.equals(group.get("actor_id")))throw conflict("需另一人复核本组接续");
        if(!Boolean.TRUE.equals(db.queryForObject("SELECT fn_finance_asset_opening_group_valid(?)",Boolean.class,id)))throw conflict("组成员、来源GL或认领条目已变化，请撤销后重新核对");
        db.update("UPDATE finance_asset_opening_groups SET status='APPROVED',approved_by=?,approved_at=now(),row_version=row_version+1 WHERE id=?",actor,id);return group(id,false);
    }
    @Transactional
    public Map<String,Object> requestRevoke(UUID id,Action action){
        UUID actor=auth.requireActorId(FinanceAssetAuthorization.EDIT);tx.bind();lockPostingStreams();var g=group(id,true);version(g,action);
        if(!Set.of("SUBMITTED","APPROVED").contains(g.get("status")))throw conflict("本组状态已变化");
        db.update("UPDATE finance_asset_opening_groups SET status='REVOKE_PENDING',revoke_actor_id=?,revoke_reason=?,row_version=row_version+1 WHERE id=?",actor,action.reason(),id);return group(id,false);
    }
    @Transactional
    public Map<String,Object> approveRevoke(UUID id,Action action){
        UUID actor=auth.requireActorId(FinanceAssetAuthorization.APPROVE);tx.bind();lockPostingStreams();var g=group(id,true);version(g,action);
        if(!"REVOKE_PENDING".equals(g.get("status"))||actor.equals(g.get("revoke_actor_id")))throw conflict("撤销接续须由另一人复核");
        for(var m:members(id)){
            boolean deferred=m.get("object_type").equals("DEFERRED_EXPENSE");String table=deferred?"deferred_expenses":"fixed_assets";
            var current=asset(new Member(m.get("object_type").toString(),(UUID)m.get("object_id"),1,0,0),true);
            if(!Set.of("DRAFT","PENDING_APPROVAL","APPROVED","ACTIVE","COMPLETED").contains(current.get("lifecycle_status")))throw conflict("成员已有处置/终止/其他撤销流程，不能直接撤销本次接续");
            int active=db.queryForObject("SELECT count(*) FROM "+(deferred?"da_amortization_log":"fa_depreciation_log")+" WHERE "+(deferred?"deferred_id":"asset_id")+"=? AND entry_kind='NORMAL' AND status='ACTIVE' AND amount<>0 AND NOT is_deleted",Integer.class,m.get("object_id"));
            if(active!=0)throw conflict("已有平台计提，请先按期间倒序完成红冲后再撤销本次接续；原GL保持不动");
            db.update("UPDATE "+table+" SET lifecycle_status='DRAFT',status='停用',recognition_voucher_id=NULL,"+(deferred?"recognized_on=NULL,completed_on=NULL":"capitalized_on=NULL")+",opening_as_of=NULL,"+(deferred?"opening_amortized_amount":"opening_accumulated_amount")+"=0,opening_remaining_months=NULL,"+(deferred?"":"opening_voucher_id=NULL,")+"submitted_at=NULL,submitted_by=NULL,approved_at=NULL,approved_by=NULL,cost_style_snapshot_id=NULL,accumulated_style_snapshot_id=NULL,expense_style_snapshot_id=NULL,clearing_style_snapshot_id=NULL,account_snapshot='{}'::jsonb,required_document_codes_snapshot='[]'::jsonb,category_version_snapshot=NULL,row_version=row_version+1,updated_at=now(),updated_by=? WHERE id=?",actor,m.get("object_id"));
            if(deferred)db.update("UPDATE finance_deferral_schedule_versions SET is_deleted=true,deleted_at=now(),deleted_by=? WHERE deferred_id=? AND NOT is_deleted",actor,m.get("object_id"));
            else db.update("UPDATE finance_asset_books SET is_deleted=true,deleted_at=now(),deleted_by=?,posting_enabled=false,status='CLOSED',closed_at=now() WHERE asset_id=? AND NOT is_deleted",actor,m.get("object_id"));
            event(m.get("object_type").toString(),(UUID)m.get("object_id"),id,"撤销本次旧账接续，保留原GL",action.reason(),actor);
        }
        db.update("DELETE FROM finance_asset_opening_entry_claims WHERE group_id=?",id);
        db.update("UPDATE finance_asset_opening_members SET active=false WHERE group_id=?",id);
        db.update("UPDATE finance_asset_opening_groups SET status='REVOKED',revoke_approved_by=?,revoked_at=now(),row_version=row_version+1 WHERE id=?",actor,id);return group(id,false);
    }

    private List<Map<String,Object>> history(FinanceTemplateSourceReader.Preview source,FinanceTemplateSourceReader.Row row,Member m,BigDecimal total,String reason){
        int year=YearMonth.parse(source.period()).getYear();boolean deferred=m.objectType().equals("DEFERRED_EXPENSE"),completed=source.template().equals("depreciationCompleted");
        List<Map<String,Object>> result=new ArrayList<>();
        months(result,row,m,deferred?10:12,completed?2025:year,source.period());
        months(result,row,m,deferred?30:24,completed?2024:year-1,source.period());
        if(!deferred&&!completed){
            int before=result.size();months(result,row,m,42,year-2,source.period());
            if(result.size()==before&&numberOrZero(row,54).signum()!=0)addHistory(result,row,m,54,(year-2)+"-01",(year-2)+"-12",number(row,54),"");
            if(numberOrZero(row,55).signum()!=0)addHistory(result,row,m,55,null,(year-3)+"-12",number(row,55),"");
        }
        if(deferred){
            boolean prior=result.stream().anyMatch(h->Objects.toString(h.get("to"),"").startsWith((year-1)+"-"));
            if(!prior&&numberOrZero(row,42).signum()!=0)addHistory(result,row,m,42,(year-1)+"-01",(year-1)+"-12",number(row,42),"");
        }
        BigDecimal sum=result.stream().map(h->decimal(h.get("amount"))).reduce(BigDecimal.ZERO,BigDecimal::add);
        BigDecimal difference=total.subtract(sum);
        if(completed&&difference.signum()>0){addHistory(result,row,m,0,null,"2023-12",difference,"原表完成分类，原值扣除明确残值及2024-2025累计后的较早年度折旧；"+reason);difference=BigDecimal.ZERO;}
        if(difference.signum()!=0) {
            addHistory(result,row,m,-1,null,source.period(),difference,"来源累计与逐月/较早年度列金额差异，月份归属未明确，不填入任何月；"+reason);
        }
        return result;
    }
    private void months(List<Map<String,Object>> out,FinanceTemplateSourceReader.Row row,Member m,int first,int year,String cutoff){for(int index=0;index<12;index++){
        int col=first+index;String period=String.format(Locale.ROOT,"%04d-%02d",year,12-index);var cell=cell(row,col);if(cell==null||cell.number()==null)continue;
        BigDecimal value=new BigDecimal(cell.number());if(period.compareTo(cutoff)>0){if(value.signum()!=0)throw invalid("原表存在接续日之后的已计提金额，请核对会计月份");continue;}
        addHistory(out,row,m,col,period,period,value,"");}}
    private void addHistory(List<Map<String,Object>> out,FinanceTemplateSourceReader.Row row,Member m,int col,String from,String to,BigDecimal value,String reason){
        var h=new LinkedHashMap<String,Object>();h.put("type",m.objectType());h.put("id",m.objectId());h.put("from",from);h.put("to",to);h.put("amount",money(value));h.put("reported",value.toPlainString());h.put("row",row.sourceRow());h.put("column",col);h.put("reason",reason);out.add(h);
    }
    private void importMetadata(Create input,FinanceTemplateSourceReader.Preview source,Member m){
        boolean deferred=m.objectType().equals("DEFERRED_EXPENSE");var row=source.rows().stream().filter(r->r.sourceRow()==m.sourceRow()).findFirst().orElseThrow();
        var versions=db.queryForList("SELECT row_version FROM finance_asset_template_metadata WHERE object_type=? AND object_id=? AND valid_from=?",Long.class,m.objectType(),m.objectId(),input.asOf());
        LocalDate documentDate=null;try{documentDate=LocalDate.parse(text(row,deferred?6:8).substring(0,10));}catch(RuntimeException ignored){ }
        metadata.save(new com.uten.imp.features.finance.asset.api.AssetTemplateContracts.Save(
            UUID.nameUUIDFromBytes((input.requestId()+":"+m.objectType()+":"+m.objectId()).getBytes(StandardCharsets.UTF_8)),
            m.objectType(),m.objectId(),input.asOf(),versions.isEmpty()?-1:versions.getFirst(),
            text(row,deferred?2:3),deferred?"":text(row,7),text(row,5),text(row,4),text(row,1),documentDate,
            text(row,deferred?22:37),deferred?text(row,23):"",text(row,deferred?27:39),!text(row,deferred?22:37).isBlank(),
            source.sourceName()+" / "+source.sourceSheet()+" / 第"+m.sourceRow()+"行 / SHA256:"+source.sha256(),deferred?"":text(row,2)));
    }
    private Map<String,Object> asset(Member m,boolean lock){boolean deferred=m.objectType().equals("DEFERRED_EXPENSE");String table=deferred?"deferred_expenses":"fixed_assets";
        var rows=db.queryForList("SELECT a.*,a."+(deferred?"total_amount":"original_value")+" AS original_amount,"+(deferred?"0::numeric":"a.salvage_rate")+" AS residual_rate,COALESCE(a.cost_style_snapshot_id,c.cost_style_id) AS cost_style_id,"+(deferred?"NULL::uuid":"COALESCE(a.accumulated_style_snapshot_id,c.accumulated_style_id)")+" AS accumulated_style_id FROM "+table+" a LEFT JOIN finance_asset_categories c ON c.id=a.category_id WHERE a.id=? AND NOT a.is_deleted"+(lock?" FOR UPDATE OF a":""),m.objectId());if(rows.size()!=1)throw invalid("所选资产或待摊记录不存在");return rows.getFirst();}
    private Map<String,Object> group(UUID id,boolean lock){var rows=db.queryForList("SELECT * FROM finance_asset_opening_groups WHERE id=?"+(lock?" FOR UPDATE":""),id);if(rows.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"接续组不存在");var g=rows.getFirst();
        for(String field:List.of("source_entry_snapshot","member_snapshot","zero_balance_evidence")){Object value=g.remove(field);try{g.put(field,json.readValue(value.toString(),Object.class));}catch(Exception e){throw new IllegalStateException("接续组来源快照无效",e);}}
        Object vouchers=g.remove("source_voucher_ids");try{g.put("sourceVoucherIds",vouchers instanceof java.sql.Array array?Arrays.asList((Object[])array.getArray()):g.get("source_voucher_id")==null?List.of():List.of(g.get("source_voucher_id")));}catch(java.sql.SQLException e){throw new IllegalStateException("接续组凭证组合无效",e);}
        g.put("version",g.get("row_version"));g.put("members",members(id));return castExact(g);}
    private List<Map<String,Object>> members(UUID id){var rows=db.queryForList("SELECT * FROM finance_asset_opening_members WHERE group_id=? ORDER BY source_row",id);
        for(var row:rows){row.put("originalAmount",decimal(row.remove("original_amount")).toPlainString());row.put("accumulatedAmount",decimal(row.remove("accumulated_amount")).toPlainString());}return rows.stream().map(FinanceAssetOpeningGroupService::castExact).toList();}
    private void event(String type,UUID object,UUID group,String title,String reason,UUID actor){db.update("INSERT INTO finance_asset_events(object_type,object_id,event_type,title,description,payload,actor_user_id) VALUES(?,?,'UPDATED',?,?,?::jsonb,?)",type,object,title,reason,encode(Map.of("openingGroupId",group,"originalGlPreserved",true)),actor);}
    private static void version(Map<String,Object> g,Action action){if(action==null||action.reason()==null||action.reason().isBlank())throw invalid("请填写复核/撤销依据");if(((Number)g.get("row_version")).longValue()!=action.expectedVersion())throw conflict("接续组已变化，请刷新核对");}
    private void lock(String value){db.query("SELECT pg_advisory_xact_lock(hashtextextended(?,997))",rs->{},"asset-opening:"+value);}
    private void lockPostingStreams(){for(String kind:List.of("AMORTIZATION","DEPRECIATION"))db.query("SELECT pg_advisory_xact_lock(hashtextextended(?,0))",rs->{},"FINANCE_ASSET_RUN|"+kind+"|CORPORATE");}
    private String encode(Object v){try{return json.writeValueAsString(exact(v));}catch(Exception e){throw new IllegalStateException("接续资料无法编码",e);}}
    @SuppressWarnings("unchecked") private static Map<String,Object> castExact(Map<String,Object> value){return (Map<String,Object>)exact(value);}
    private static Object exact(Object value){
        if(value instanceof BigDecimal amount)return amount.toPlainString();
        if(value instanceof Map<?,?> map){var result=new LinkedHashMap<String,Object>();map.forEach((k,v)->result.put(k.toString(),exact(v)));return result;}
        if(value instanceof Collection<?> values)return values.stream().map(FinanceAssetOpeningGroupService::exact).toList();
        return value;
    }
    private static boolean same(Map<UUID,BigDecimal>a,Map<UUID,BigDecimal>b){return a.keySet().equals(b.keySet())&&a.entrySet().stream().allMatch(e->e.getValue().compareTo(b.get(e.getKey()))==0);}
    private static FinanceTemplateSourceReader.Cell cell(FinanceTemplateSourceReader.Row row,int col){return row.cells().stream().filter(c->c.column()==col).findFirst().orElse(null);}
    private static String text(FinanceTemplateSourceReader.Row row,int col){var c=cell(row,col);return c==null?"":c.text();}
    private static BigDecimal number(FinanceTemplateSourceReader.Row row,int col){var c=cell(row,col);if(c==null||c.number()==null)throw invalid("原表第"+row.sourceRow()+"行第"+col+"列缺少明确数字");return new BigDecimal(c.number());}
    private static BigDecimal numberOrZero(FinanceTemplateSourceReader.Row row,int col){var c=cell(row,col);return c==null||c.number()==null?BigDecimal.ZERO:new BigDecimal(c.number());}
    private static BigDecimal decimal(Object v){return v==null?BigDecimal.ZERO:new BigDecimal(v.toString());}
    private static BigDecimal money(BigDecimal v){return FinancialExactAmount.book(v,"原表账面金额");}
    private static LocalDate date(Object v){return v instanceof java.sql.Date d?d.toLocalDate():LocalDate.parse(v.toString());}
    private static ApiException invalid(String m){return new ApiException(ErrorCode.VALIDATION_FAILED,m);}
    private static ApiException conflict(String m){return new ApiException(ErrorCode.CONFLICT,m);}

    /** Full selected lifecycle range through bounded summary batches; original detail/write contracts are unchanged. */
    public com.uten.imp.common.readsnapshot.VersionedSummaryPages.Page<Map<String,Object>> summaries(String requestedScope,int page,int size,String revision) {
        auth.require(FinanceAssetAuthorization.VIEW);
        String scope=com.uten.imp.common.readsnapshot.VersionedSummaryPages.scope(requestedScope);
        String where="TRUE"+switch(scope) {
            case "active" -> " AND (status IN ('SUBMITTED','REVOKE_PENDING'))";
            case "history" -> " AND (status IN ('APPROVED','REVOKED'))";
            default -> "";
        };
        var request=new com.uten.imp.common.readsnapshot.VersionedSummaryPages.Request("finance-asset-opening-groups","finance",Map.of("company",true),scope,page,size,1000,revision);
        return summaryPages.page(request,()->{auth.require(FinanceAssetAuthorization.VIEW);},
                ()->db.queryForObject("SELECT count(*) FROM finance_asset_opening_groups WHERE "+where,Long.class),
                (readPage,readSize)->db.queryForList("SELECT id,as_of,source_voucher_id,status,row_version AS version,created_at,reason FROM finance_asset_opening_groups WHERE "+where+" ORDER BY created_at DESC,id DESC LIMIT ? OFFSET ?",readSize,Math.multiplyExact((long)readPage-1,readSize)));
    }
}
