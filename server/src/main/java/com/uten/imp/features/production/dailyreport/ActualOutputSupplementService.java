package com.uten.imp.features.production.dailyreport;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.ProductionWorkshopMembership;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import com.uten.imp.features.production.fulfillment.ProductionExecutionReadinessService;
import com.uten.imp.features.production.plan.ProductionPlanService;
import com.uten.imp.features.production.plan.dto.PlanItemLine;
import com.uten.imp.features.production.plan.dto.PlanSaveRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.BeanUtils;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import static com.uten.imp.features.production.dailyreport.ActualOutputSupplementContracts.*;

/** Explicit additional-plan approval, followed by one conserved physical report. */
@Service
@RequiredArgsConstructor
public class ActualOutputSupplementService {
    private final NamedParameterJdbcTemplate db;
    private final EntityManager em;
    private final SecurityContextCurrentUser user;
    private final ProductionDocumentAccessPolicy access;
    private final ProductionWorkshopMembership membership;
    private final TxSessionVars tx;
    private final DailyReportOutputAllocationService output;
    private final ProductionPlanService plans;
    private final ProductionExecutionReadinessService readiness;
    private final com.fasterxml.jackson.databind.ObjectMapper mapper;
    private final com.uten.imp.features.production.plan.ProductionPlanMutationFootprintService planFootprints;
    private final com.uten.imp.common.mastercode.MasterCodeService masterCodes;

    @Transactional
    public Preview preview(PreviewRequest request) {
        tx.bind();
        var context=context(request.sourceExecutionSegmentId(),true);
        requireSourceAccess(context);
        return previewLocked(request,context);
    }
    @Transactional
    public ReportPreview previewReport(ReportPreviewRequest request) {
        return previewReportForOwner(request,user.requireId());
    }
    private ReportPreview previewReportForOwner(ReportPreviewRequest request,UUID capturedBy) {
        tx.bind();
        if(request.report()==null||request.report().getItems()==null)throw invalid("缺少完整报工批次");
        var originals=request.report().getItems();
        if(originals.stream().anyMatch(line->line==null||line.getQty()==null||line.getQty().signum()<=0||line.getExecutionSegmentId()==null))
            throw invalid("每行必须选择真实工单并填写正数实际产量");
        UUID excluded=request.excludedReportId()==null?UUID.randomUUID():request.excludedReportId();
        requireEditableExcludedReport(request.excludedReportId());
        Map<UUID,Map<String,Object>> contexts=new HashMap<>();
        for(UUID segment:originals.stream().map(DailyReportItemLine::getExecutionSegmentId).distinct().sorted().toList()) {
            var c=context(segment,true);requireSourceAccess(c);contexts.put(segment,c);
        }
        var workshops=contexts.values().stream().map(c->uuid(c,"workshop_department_id")).collect(java.util.stream.Collectors.toSet());
        if(workshops.size()!=1||!workshops.contains(request.report().getDepartmentId()))throw invalid("完整报工批次必须属于同一车间，且与日报车间一致");
        List<DailyReportItemLine> numbered=new ArrayList<>();
        for(int index=0;index<originals.size();index++){var copy=new DailyReportItemLine();BeanUtils.copyProperties(originals.get(index),copy);copy.setInputLineIndex(index);numbered.add(copy);}
        bindReviewedInputProofs(request.report(),numbered,capturedBy);
        var proofIds=numbered.stream().map(DailyReportItemLine::getSupplementProofId).filter(Objects::nonNull).distinct().toList();
        var slices=output.splitForPreview(excluded,expandInternal(excluded,numbered,false),proofIds);
        Map<UUID,BigDecimal> totals=new HashMap<>();Map<Integer,BigDecimal> extras=new HashMap<>();Map<Integer,BigDecimal> salesSlices=new HashMap<>();
        for(var slice:slices){
            if(!slice.isActualSurplus()&&slice.getExecutionSegmentSalesAllocationId()!=null)salesSlices.merge(slice.getInputLineIndex(),slice.getQty(),BigDecimal::add);
            if(slice.isActualSurplus()&&slice.getFqcRecoveryAuthorizationId()==null){
            totals.merge(slice.getExecutionSegmentId(),slice.getQty(),BigDecimal::add);
            extras.merge(slice.getInputLineIndex(),slice.getQty(),BigDecimal::add);
        }}
        String contextHash=ProductionDailyReportService.createRequestHash(request.report());
        List<ReportLinePreview> previews=new ArrayList<>();
        for(int index=0;index<originals.size();index++) {
            var line=originals.get(index);var c=contexts.get(line.getExecutionSegmentId());
            BigDecimal extra=extras.getOrDefault(index,BigDecimal.ZERO);
            BigDecimal salesPart=salesSlices.getOrDefault(index,BigDecimal.ZERO);
            BigDecimal available=db.queryForObject("SELECT fn_execution_actual_surplus_available(:segment,:report)",args("segment",line.getExecutionSegmentId(),"report",excluded),BigDecimal.class);
            boolean required=line.getSupplementProofId()==null&&extra.signum()>0&&totals.getOrDefault(line.getExecutionSegmentId(),BigDecimal.ZERO).compareTo(available)>0;
            String fingerprint=hash(contextHash+"|"+index+"|"+extra.stripTrailingZeros()+"|"+salesPart.stripTrailingZeros()+"|"+available.stripTrailingZeros()+"|"+number(c,"planned_qty").stripTrailingZeros()+"|"+number(c,"allowed_overproduction_rate").stripTrailingZeros());
            previews.add(new ReportLinePreview(index,line.getExecutionSegmentId(),line.getExecutionSegmentSalesAllocationId(),line.getQty(),line.getQty().subtract(extra),extra,available,required,fingerprint,salesPart,line.getQty().subtract(extra).subtract(salesPart)));
        }
        return new ReportPreview(List.copyOf(previews),previews.stream().anyMatch(ReportLinePreview::requiresSupplement));
    }
    /** A saved whole-form snapshot can outlive approval of another row in that same form. */
    private void bindReviewedInputProofs(com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest input,
                                        List<DailyReportItemLine> lines,UUID capturedBy) {
        if(input.getIdempotencyKey()==null||input.getIdempotencyKey().isBlank())return;
        var bindings=db.queryForList("""
                SELECT request.input_line_index,request.source_execution_segment_id,request.source_sales_allocation_id,
                       request.actual_batch_qty,proof.id
                FROM production_actual_output_supplement_requests request
                JOIN production_actual_output_supplement_proofs proof ON proof.command_id=request.id
                WHERE request.created_by=:actor AND request.report_context->>'idempotencyKey'=:key
                  AND request.status='APPROVED'
                  AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_reversals reversal WHERE reversal.proof_id=proof.id)
                ORDER BY request.input_line_index
                """,args("actor",capturedBy,"key",input.getIdempotencyKey()));
        Set<Integer> bound=new HashSet<>();
        for(var binding:bindings) {
            int index=((Number)binding.get("input_line_index")).intValue();
            if(index<0||index>=lines.size()||!bound.add(index))throw conflict("原表的追加计划行身份重复或已变化，请核对申请时整单快照");
            var line=lines.get(index);
            if(!Objects.equals(line.getExecutionSegmentId(),binding.get("source_execution_segment_id"))
                    ||!Objects.equals(line.getExecutionSegmentSalesAllocationId(),binding.get("source_sales_allocation_id"))
                    ||line.getQty().compareTo(number(binding,"actual_batch_qty"))!=0
                    ||line.getFqcRecoveryAuthorizationId()!=null
                    ||(line.getSupplementProofId()!=null&&!Objects.equals(line.getSupplementProofId(),binding.get("id"))))
                throw conflict("原表已有批准追加计划，其行索引、来源和实际总量不能改挂另一批次");
            line.setSupplementProofId(uuid(binding,"id"));
        }
    }
    private void requireEditableExcludedReport(UUID excluded) {
        if(excluded==null)return;
        var report=one("SELECT maker_id,status FROM production_daily_reports WHERE id=:id AND NOT is_deleted",args("id",excluded));
        access.requireReadable(uuid(report,"maker_id"),"报工草稿不存在","production_plan:approve");
        if(((Number)report.get("status")).intValue()!=0)throw invalid("仅报工草稿可排除自身占额");
    }
    private Preview previewLocked(PreviewRequest request,Map<String,Object> c) {
        if(request.actualQty()==null || request.actualQty().signum()<=0 || request.actualQty().stripTrailingZeros().scale()>4)
            throw invalid("实际产量必须大于零，最多四位小数");
        var line=new DailyReportItemLine();
        line.setExecutionSegmentId(request.sourceExecutionSegmentId());line.setPlanItemId(uuid(c,"source_plan_item_id"));
        line.setGoodsId(uuid(c,"product_goods_id"));line.setColorId(uuid(c,"product_color_id"));
        line.setUnitId(uuid(c,"product_unit_id"));line.setUnitRate(number(c,"product_unit_rate"));line.setQty(request.actualQty());
        line.setDestination("WAREHOUSE");line.setExecutionSegmentSalesAllocationId(request.sourceSalesAllocationId());
        if(request.sourceSalesAllocationId()!=null) {
            var allocation=one("SELECT sales_order_item_id FROM execution_segment_sales_allocations WHERE id=:id AND execution_segment_id=:segment",
                    args("id",request.sourceSalesAllocationId(),"segment",request.sourceExecutionSegmentId()));
            line.setSalesOrderItemId(uuid(allocation,"sales_order_item_id"));
        }
        UUID excluded=request.excludedReportId()==null?UUID.randomUUID():request.excludedReportId();
        requireEditableExcludedReport(request.excludedReportId());
        var slices=output.split(excluded,List.of(line));
        BigDecimal extra=slices.stream().filter(DailyReportItemLine::isActualSurplus).map(DailyReportItemLine::getQty).reduce(BigDecimal.ZERO,BigDecimal::add);
        BigDecimal salesPart=slices.stream().filter(linePart->linePart.getExecutionSegmentSalesAllocationId()!=null).map(DailyReportItemLine::getQty).reduce(BigDecimal.ZERO,BigDecimal::add);
        BigDecimal available=db.queryForObject("SELECT fn_execution_actual_surplus_available(:segment,:excluded)",args("segment",request.sourceExecutionSegmentId(),"excluded",excluded),BigDecimal.class);
        BigDecimal prior=db.queryForObject("""
                SELECT COALESCE(SUM(item.qty),0) FROM production_daily_report_items item
                JOIN production_daily_reports report ON report.id=item.report_id
                WHERE item.execution_segment_id=:segment AND item.fqc_recovery_authorization_id IS NULL
                  AND report.status=1 AND NOT report.is_deleted AND NOT item.is_deleted
                """,args("segment",request.sourceExecutionSegmentId()),BigDecimal.class);
        BigDecimal rate=number(c,"allowed_overproduction_rate"),planned=number(c,"planned_qty");
        String fingerprint=hash(request.sourceExecutionSegmentId()+"|"+request.sourceSalesAllocationId()+"|"+request.actualQty().stripTrailingZeros()
                +"|"+planned.stripTrailingZeros()+"|"+prior.stripTrailingZeros()+"|"+rate.stripTrailingZeros()+"|"+available.stripTrailingZeros()+"|"+extra.stripTrailingZeros()+"|"+salesPart.stripTrailingZeros());
        return new Preview(request.sourceExecutionSegmentId(),uuid(c,"plan_id"),Objects.toString(c.get("plan_no"),""),Objects.toString(c.get("segment_code"),""),
                uuid(c,"product_goods_id"),uuid(c,"product_color_id"),uuid(c,"product_unit_id"),number(c,"product_unit_rate"),
                uuid(c,"workshop_department_id"),uuid(c,"responsible_employee_id"),planned,prior,rate,
                planned.multiply(BigDecimal.ONE.add(rate)).setScale(4,RoundingMode.DOWN),available,request.actualQty(),request.actualQty().subtract(extra),extra,
                extra.compareTo(available)>0,fingerprint,request.sourceSalesAllocationId(),salesPart,request.actualQty().subtract(extra).subtract(salesPart));
    }

    @Transactional
    public View create(CreateRequest request) {
        tx.bind();lockCommand(request.idempotencyKey());
        String requestHash=hash(request.sourceExecutionSegmentId()+"|"+request.actualQty().stripTrailingZeros()+"|"+request.sourceSalesAllocationId()+"|"+request.fingerprint()+"|"+request.billDate()+"|"+request.deliveryDate()+"|"+request.remark()+"|"+request.excludedReportId()+"|"+request.inputLineIndex()+"|"+(request.reportContext()==null?"":ProductionDailyReportService.createRequestHash(request.reportContext())));
        var existing=db.queryForList("SELECT id,request_hash FROM production_actual_output_supplement_requests WHERE created_by=:actor AND idempotency_key=:key",
                args("actor",user.requireId(),"key",request.idempotencyKey()));
        if(!existing.isEmpty()) {
            if(!requestHash.equals(existing.getFirst().get("request_hash")))throw conflict("同一幂等键对应不同追加计划请求");
            return detail(uuid(existing.getFirst(),"id"));
        }
        if(request.reportContext()!=null&&request.reportContext().getIdempotencyKey()!=null) {
            lockCommand("FORM:"+request.reportContext().getIdempotencyKey()+":"+request.inputLineIndex());
            var captured=db.queryForList("""
                    SELECT id,request_hash FROM production_actual_output_supplement_requests
                    WHERE created_by=:actor AND report_context->>'idempotencyKey'=:key
                      AND input_line_index=:index AND status<>'CANCELLED'
                    """,args("actor",user.requireId(),"key",request.reportContext().getIdempotencyKey(),"index",request.inputLineIndex()));
            if(!captured.isEmpty()) {
                if(!requestHash.equals(captured.getFirst().get("request_hash")))throw conflict("本表该行已有追加申请，请先处理原申请，不能换命令键重复申请同一批实产");
                return detail(uuid(captured.getFirst(),"id"));
            }
        }
        var discovered=context(request.sourceExecutionSegmentId(),false);requireSourceAccess(discovered);
        Set<UUID> sourcePlans=new TreeSet<>();sourcePlans.add(uuid(discovered,"plan_id"));
        if(request.reportContext()!=null)for(var line:request.reportContext().getItems()) {
            if(line==null||line.getExecutionSegmentId()==null)throw invalid("完整批次缺少来源工单");
            var related=context(line.getExecutionSegmentId(),false);requireSourceAccess(related);sourcePlans.add(uuid(related,"plan_id"));
        }
        var creationGuard=planFootprints.beginPlans(sourcePlans);
        var source=context(request.sourceExecutionSegmentId(),true);
        Preview preview;
        if(request.reportContext()!=null) {
            var batch=previewReport(new ReportPreviewRequest(request.reportContext(),request.excludedReportId()));
            if(request.inputLineIndex()==null||request.inputLineIndex()<0||request.inputLineIndex()>=batch.lines().size())throw invalid("追加预览必须指向本次输入行");
            var line=batch.lines().get(request.inputLineIndex());
            if(!Objects.equals(line.sourceExecutionSegmentId(),request.sourceExecutionSegmentId())||!Objects.equals(line.sourceSalesAllocationId(),request.sourceSalesAllocationId())||line.actualQty().compareTo(request.actualQty())!=0)
                throw invalid("追加计划输入行与完整批次不一致");
            BigDecimal prior=db.queryForObject("SELECT COALESCE(SUM(item.qty),0) FROM production_daily_report_items item JOIN production_daily_reports report ON report.id=item.report_id WHERE item.execution_segment_id=:id AND report.status=1 AND NOT report.is_deleted AND NOT item.is_deleted AND item.fqc_recovery_authorization_id IS NULL",args("id",request.sourceExecutionSegmentId()),BigDecimal.class);
            BigDecimal planned=number(source,"planned_qty"),rate=number(source,"allowed_overproduction_rate");
            preview=new Preview(request.sourceExecutionSegmentId(),uuid(source,"plan_id"),Objects.toString(source.get("plan_no")),Objects.toString(source.get("segment_code")),uuid(source,"product_goods_id"),uuid(source,"product_color_id"),uuid(source,"product_unit_id"),number(source,"product_unit_rate"),uuid(source,"workshop_department_id"),uuid(source,"responsible_employee_id"),planned,prior,rate,planned.multiply(BigDecimal.ONE.add(rate)).setScale(4,RoundingMode.DOWN),line.remainingActualSurplusQty(),line.actualQty(),line.originalReportQty(),line.supplementQty(),line.requiresSupplement(),line.fingerprint(),line.sourceSalesAllocationId(),line.originalSalesQty(),line.originalInternalQty());
        } else preview=previewLocked(new PreviewRequest(request.sourceExecutionSegmentId(),request.actualQty(),request.sourceSalesAllocationId(),request.excludedReportId()),source);
        if(!preview.fingerprint().equals(request.fingerprint()))throw conflict("原工单报工、比例或占额已变化，请重新核对追加计划预览");
        if(!preview.requiresSupplement())throw invalid("本次实际产量未超过当前批准的超产额度，无须新建追加计划");
        creationGuard.verifyUnchanged();
        var planRequest=new PlanSaveRequest();planRequest.setBillDate(request.billDate());planRequest.setDeliveryDate(request.deliveryDate());
        planRequest.setDepartmentId(preview.workshopDepartmentId());planRequest.setWorkerId(preview.responsibleEmployeeId());
        planRequest.setFStyle("实际超产追加");planRequest.setSourceDocNo(preview.sourcePlanNo());planRequest.setRemark(request.remark());
        var product=new PlanItemLine();product.setGoodsId(preview.goodsId());product.setColorId(preview.colorId());product.setUnitId(preview.unitId());
        product.setUnitRate(preview.unitRate());product.setQty(preview.supplementQty());product.setPlanBeginDate(request.billDate());product.setPlanEndDate(request.deliveryDate());
        planRequest.setItems(List.of(product));
        var created=plans.create(planRequest);
        UUID id=UUID.randomUUID();
        db.update("""
                INSERT INTO production_actual_output_supplement_requests(id,source_execution_segment_id,source_sales_allocation_id,excluded_report_id,report_context,input_line_index,
                    supplement_plan_id,supplement_plan_item_id,batch_id,actual_batch_qty,original_report_qty,supplement_qty,
                    prior_reported_qty,source_planned_qty,allowed_overproduction_rate,preview_fingerprint,request_hash,idempotency_key,created_by,original_sales_qty,original_internal_qty)
                VALUES(:id,:source,:allocation,:excluded,CAST(:context AS jsonb),:lineIndex,:plan,:item,:batch,:actual,:original,:supplement,:prior,:planned,:rate,:fingerprint,:hash,:key,:actor,:salesQty,:internalQty)
                """,args("id",id,"source",preview.sourceSegmentId(),"allocation",preview.sourceSalesAllocationId(),"plan",created.getId(),"item",created.getItems().getFirst().getId(),
                "batch",UUID.randomUUID(),"actual",preview.actualQty(),"original",preview.originalReportQty(),"supplement",preview.supplementQty(),"prior",preview.priorReportedQty(),
                "planned",preview.plannedQty(),"rate",preview.effectiveRate(),"fingerprint",preview.fingerprint(),"hash",requestHash,"key",request.idempotencyKey(),"actor",user.requireId(),
                "excluded",request.excludedReportId(),"context",json(request.reportContext()),"lineIndex",request.inputLineIndex(),"salesQty",preview.originalSalesQty(),"internalQty",preview.originalInternalQty()));
        db.update("UPDATE production_plans SET actual_output_supplement_request_id=:id WHERE id=:plan",args("id",id,"plan",created.getId()));
        return detail(id);
    }

    @Transactional(readOnly=true)
    public View detail(UUID id) {
        var r=request(id,false);requireSourceAccess(context(uuid(r,"source_execution_segment_id"),false));
        var proof=db.queryForList("SELECT proof.id,proof.supplement_execution_segment_id,segment.lock_version,segment.status FROM production_actual_output_supplement_proofs proof JOIN production_execution_segments segment ON segment.id=proof.supplement_execution_segment_id WHERE proof.command_id=:id",args("id",id));
        String targetStatus=proof.isEmpty()?null:Objects.toString(proof.getFirst().get("status"));
        var context=authorizedReportContext(r);
        String contextKey=context==null?null:context.getIdempotencyKey();
        List<RelatedSupplement> related=context==null?List.of():db.queryForList("""
                SELECT request.id,request.input_line_index,request.source_execution_segment_id,request.source_sales_allocation_id,
                       request.actual_batch_qty,request.status,proof.id AS proof_id,proof.supplement_execution_segment_id,segment.status AS segment_status
                FROM production_actual_output_supplement_requests request
                LEFT JOIN production_actual_output_supplement_proofs proof ON proof.command_id=request.id
                LEFT JOIN production_execution_segments segment ON segment.id=proof.supplement_execution_segment_id
                WHERE request.created_by=:creator AND ((CAST(:contextKey AS text) IS NOT NULL AND request.report_context->>'idempotencyKey'=CAST(:contextKey AS text)) OR request.id=:id)
                ORDER BY request.input_line_index NULLS LAST,request.created_at,request.id
                """,args("creator",uuid(r,"created_by"),"contextKey",contextKey,"id",id)).stream().map(row->new RelatedSupplement(uuid(row,"id"),
                    row.get("input_line_index")==null?null:((Number)row.get("input_line_index")).intValue(),uuid(row,"source_execution_segment_id"),uuid(row,"source_sales_allocation_id"),number(row,"actual_batch_qty"),uuid(row,"proof_id"),Objects.toString(row.get("status")),uuid(row,"supplement_execution_segment_id"),Objects.toString(row.get("segment_status"),null))).toList();
        return new View(id,Objects.toString(r.get("status")),uuid(r,"supplement_plan_id"),Objects.toString(r.get("plan_no")),
                proof.isEmpty()?null:uuid(proof.getFirst(),"id"),proof.isEmpty()?null:uuid(proof.getFirst(),"supplement_execution_segment_id"),
                proof.isEmpty()?null:((Number)proof.getFirst().get("lock_version")).longValue(),number(r,"actual_batch_qty"),number(r,"original_report_qty"),number(r,"supplement_qty"),uuid(r,"source_execution_segment_id"),
                targetStatus,Set.of("READY","DISPATCHED").contains(Objects.toString(targetStatus,""))&&access.hasAuthority("production_execution:start"),sourceLine(r),
                context,r.get("input_line_index")==null?null:((Number)r.get("input_line_index")).intValue(),uuid(r,"excluded_report_id"),related,inputSources(context));
    }

    @Transactional
    public View approve(UUID id,ApproveRequest command) {
        tx.bind();lockCommand(command.idempotencyKey());var observed=request(id,false);
        var sourceObserved=context(uuid(observed,"source_execution_segment_id"),false);
        var guard=planFootprints.beginPlans(List.of(uuid(sourceObserved,"plan_id"),uuid(observed,"supplement_plan_id")));
        var r=request(id,true);
        if("APPROVED".equals(r.get("status")))return detail(id);
        if(!"DRAFT".equals(r.get("status")))throw conflict("追加计划申请已取消");
        var source=context(uuid(r,"source_execution_segment_id"),true);
        access.requireWritable(uuid(r,"plan_maker_id"),"无权审核此追加生产计划","production_plan:approve");
        BigDecimal originalNow,additionalNow,salesNow;
        if(r.get("report_context")!=null) {
            var input=readContext(r.get("report_context").toString());
            var preview=previewReportForOwner(new ReportPreviewRequest(input,uuid(r,"excluded_report_id")),uuid(r,"created_by")).lines().get(((Number)r.get("input_line_index")).intValue());
            originalNow=preview.originalReportQty();additionalNow=preview.supplementQty();salesNow=preview.originalSalesQty();
        } else {
            Preview now=previewLocked(new PreviewRequest(uuid(r,"source_execution_segment_id"),number(r,"actual_batch_qty"),uuid(r,"source_sales_allocation_id"),uuid(r,"excluded_report_id")),source);
            originalNow=now.originalReportQty();additionalNow=now.supplementQty();salesNow=now.originalSalesQty();
        }
        if(originalNow.compareTo(number(r,"original_report_qty"))!=0 || additionalNow.compareTo(number(r,"supplement_qty"))!=0 || salesNow.compareTo(number(r,"original_sales_qty"))!=0)
            throw conflict("原计划可承接量已变化，请取消当前追加草稿后按实际数量重新申请，不能挪用其他来源");
        guard.verifyUnchanged();
        plans.approveForActualOutputSupplement(uuid(r,"supplement_plan_id"),id);
        UUID packageId=UUID.randomUUID(),segmentId=UUID.randomUUID(),proofId=UUID.randomUUID();
        db.update("""
                INSERT INTO production_planning_packages(id,plan_id,warehouse_id,idempotency_key,request_hash,preview_fingerprint,execution_model_version,status,created_by)
                VALUES(:id,:plan,:warehouse,:key,:hash,:hash,1,'CONFIRMED',:actor)
                """,args("id",packageId,"plan",uuid(r,"supplement_plan_id"),"warehouse",uuid(source,"warehouse_id"),"key","ACTUAL-SUPPLEMENT-"+id,"hash",r.get("request_hash"),"actor",user.requireId()));
        db.update("""
                INSERT INTO production_actual_output_supplement_proofs(id,command_id,source_execution_segment_id,supplement_plan_id,supplement_plan_item_id,
                    supplement_execution_segment_id,batch_id,actual_batch_qty,original_report_qty,supplement_qty,prior_reported_qty,source_planned_qty,allowed_overproduction_rate,created_by)
                SELECT :proof,id,source_execution_segment_id,supplement_plan_id,supplement_plan_item_id,:segment,batch_id,actual_batch_qty,
                    original_report_qty,supplement_qty,prior_reported_qty,source_planned_qty,allowed_overproduction_rate,:actor
                FROM production_actual_output_supplement_requests WHERE id=:id
                """,args("proof",proofId,"segment",segmentId,"actor",user.requireId(),"id",id));
        db.update("""
                INSERT INTO production_execution_segments(id,package_id,plan_id,source_plan_item_id,segment_no,segment_code,client_segment_key,
                    product_goods_id,product_color_id,product_unit_id,product_unit_rate,planned_qty,status,workshop_department_id,team_department_id,
                    responsible_employee_id,plan_begin_date,plan_end_date,bom_fingerprint,idempotency_key,material_requirement_mode,
                    zero_material_reason,zero_material_analysis_id,zero_material_exception_reason,zero_material_authorized_by,created_by)
                SELECT :segment,:package,:plan,:item,1,:code,:key,product_goods_id,product_color_id,product_unit_id,product_unit_rate,:qty,
                    CASE WHEN material_requirement_mode='ZERO_MATERIAL' THEN 'READY' ELSE 'WAITING' END,
                    workshop_department_id,team_department_id,responsible_employee_id,plan_begin_date,plan_end_date,bom_fingerprint,:key,material_requirement_mode,
                    zero_material_reason,zero_material_analysis_id,zero_material_exception_reason,zero_material_authorized_by,:actor
                FROM production_execution_segments WHERE id=:source
                """,args("segment",segmentId,"package",packageId,"plan",uuid(r,"supplement_plan_id"),"item",uuid(r,"supplement_plan_item_id"),"code",masterCodes.nextCode(com.uten.imp.common.mastercode.MasterCodePrefix.PRODUCTION_EXECUTION_SEGMENT),
                "key","ACTUAL-SUPPLEMENT-"+id,"qty",number(r,"supplement_qty"),"actor",user.requireId(),"source",uuid(r,"source_execution_segment_id")));
        db.update("UPDATE production_actual_output_supplement_requests SET status='APPROVED' WHERE id=:id",args("id",id));
        readiness.promoteAfterMaterialRecheck(segmentId,uuid(source,"warehouse_id"));
        return detail(id);
    }

    @Transactional
    public View cancel(UUID id,CancelRequest command) {
        tx.bind();lockCommand(command.idempotencyKey());var observed=request(id,false);
        var sourceObserved=context(uuid(observed,"source_execution_segment_id"),false);
        var guard=planFootprints.beginPlans(List.of(uuid(sourceObserved,"plan_id"),uuid(observed,"supplement_plan_id")));
        var r=request(id,true);
        access.requireWritable(uuid(r,"plan_maker_id"),"无权取消此追加生产计划","production_plan:approve");
        if("CANCELLED".equals(r.get("status")))return detail(id);
        guard.verifyUnchanged();
        db.queryForObject("SELECT set_config('app.actual_output_supplement_request',:id,true)",args("id",id.toString()),String.class);
        var proofs=db.queryForList("SELECT * FROM production_actual_output_supplement_proofs WHERE command_id=:id FOR UPDATE",args("id",id));
        if(!proofs.isEmpty()) {
            var proof=proofs.getFirst();UUID proofId=uuid(proof,"id"),segment=uuid(proof,"supplement_execution_segment_id");
            if(Boolean.TRUE.equals(db.queryForObject("""
                    SELECT EXISTS(SELECT 1 FROM production_material_increment_requests increment
                        WHERE increment.target_segment_id=:segment AND increment.status IN('PENDING','APPROVED')
                          AND NOT EXISTS(SELECT 1 FROM production_material_increment_reversals reversal WHERE reversal.request_id=increment.id))
                    """,args("segment",segment),Boolean.class)))
                throw conflict("追加工单存在待审或已批准的增量用料责任，请先处理补料申请；已批准补料须沿独立撤销流程处理，不能随追加计划自动取消");
            if(Boolean.TRUE.equals(db.queryForObject("""
                    SELECT EXISTS(SELECT 1 FROM production_actual_output_supplement_claims claim WHERE proof_id=:proof AND event_type='CLAIM'
                        AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_claims release WHERE release.source_claim_id=claim.id))
                    OR EXISTS(SELECT 1 FROM production_actual_output_supplement_proofs child WHERE source_execution_segment_id=:segment
                        AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_reversals reversed WHERE reversed.proof_id=child.id))
                    OR EXISTS(SELECT 1 FROM production_daily_report_items item JOIN production_daily_reports report ON report.id=item.report_id
                        WHERE item.execution_segment_id=:segment AND NOT item.is_deleted AND NOT report.is_deleted AND report.status IN(0,1))
                    """,args("proof",proofId,"segment",segment),Boolean.class)))throw conflict("追加实产已有报工或下级追加责任，请先按原单据逐层删除草稿或红冲后取消");
            db.update("INSERT INTO production_actual_output_supplement_reversals(proof_id,reason,created_by) VALUES(:proof,:reason,:actor)",args("proof",proofId,"reason",command.reason(),"actor",user.requireId()));
            db.update("UPDATE production_planning_packages SET status='CANCELLED',lifecycle_reason=:reason WHERE id=(SELECT package_id FROM production_execution_segments WHERE id=:segment)",args("reason",command.reason(),"segment",segment));
            db.update("UPDATE production_execution_segments SET status='CANCELLED' WHERE id=:segment",args("segment",segment));
            db.update("UPDATE production_plans SET is_canceled=true WHERE id=:plan",args("plan",uuid(r,"supplement_plan_id")));
        } else {
            plans.delete(uuid(r,"supplement_plan_id"));
        }
        db.update("UPDATE production_actual_output_supplement_requests SET status='CANCELLED' WHERE id=:id",args("id",id));
        return detail(id);
    }

    public List<DailyReportItemLine> expand(UUID reportId,List<DailyReportItemLine> lines) {
        return expandInternal(reportId,lines,true);
    }
    private List<DailyReportItemLine> expandInternal(UUID reportId,List<DailyReportItemLine> lines,boolean claimBatch) {
        List<DailyReportItemLine> expanded=new ArrayList<>();Set<UUID> seen=new HashSet<>();
        for(var line:lines) {
            if(line!=null&&line.getSupplementProofId()==null&&line.getFqcRecoveryAuthorizationId()==null
                &&Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM production_actual_output_supplement_proofs WHERE supplement_execution_segment_id=:segment)",args("segment",line.getExecutionSegmentId()),Boolean.class)))
                throw invalid("追加实产工单须通过原批次的追加证明继续报工，不能单独重报或再次领耗材料");
            if(line==null || line.getSupplementProofId()==null || line.getFqcRecoveryAuthorizationId()!=null){expanded.add(line);continue;}
            if(!seen.add(line.getSupplementProofId()))throw invalid("同一实际产出批次只能在本单选择一次，请保留原总量行");
            var proof=one("""
                    SELECT proof.*,request.source_sales_allocation_id,segment.status AS target_status
                    FROM production_actual_output_supplement_proofs proof
                    JOIN production_actual_output_supplement_requests request ON request.id=proof.command_id
                    JOIN production_execution_segments segment ON segment.id=proof.supplement_execution_segment_id
                    WHERE proof.id=:id AND request.status='APPROVED'
                      AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_reversals reversed WHERE reversed.proof_id=proof.id)
                    FOR UPDATE OF proof,segment
                    """,args("id",line.getSupplementProofId()));
            if(!Objects.equals(line.getExecutionSegmentId(),proof.get("source_execution_segment_id"))
                    || !Objects.equals(line.getExecutionSegmentSalesAllocationId(),proof.get("source_sales_allocation_id"))
                    || line.getQty()==null || line.getQty().compareTo(number(proof,"actual_batch_qty"))!=0)
                throw invalid("追加证明必须对应原工单、本次完整实际产量与原精确来源");
            if(claimBatch&&!"IN_PROGRESS".equals(proof.get("target_status")))throw conflict("追加计划已审核后，还须由所属车间确认追加工单开工，再继续本批报工");
            var current=db.queryForList("""
                    SELECT claim.report_id FROM production_actual_output_supplement_claims claim WHERE proof_id=:proof AND event_type='CLAIM'
                      AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_claims release WHERE release.source_claim_id=claim.id)
                    """,args("proof",line.getSupplementProofId()));
            if(!current.isEmpty()&&!Objects.equals(current.getFirst().get("report_id"),reportId))throw conflict("本次实产已经被另一张日报承接，不能重复报工");
            if(claimBatch&&current.isEmpty())db.update("INSERT INTO production_actual_output_supplement_claims(proof_id,report_id,event_type,created_by) VALUES(:proof,:report,'CLAIM',:actor)",args("proof",line.getSupplementProofId(),"report",reportId,"actor",user.requireId()));
            BigDecimal original=number(proof,"original_report_qty"),extra=number(proof,"supplement_qty");
            var split=new ArrayList<DailyReportItemLine>();
            if(original.signum()>0){var own=new DailyReportItemLine();BeanUtils.copyProperties(line,own);own.setQty(original);split.add(own);}
            var additional=new DailyReportItemLine();BeanUtils.copyProperties(line,additional);additional.setQty(extra);
            additional.setExecutionSegmentId(uuid(proof,"supplement_execution_segment_id"));additional.setPlanItemId(uuid(proof,"supplement_plan_item_id"));
            additional.setExecutionSegmentSalesAllocationId(null);additional.setSalesOrderItemId(null);additional.setSalesOrderNo(null);additional.setClientName(null);
            additional.setDestination("WAREHOUSE");additional.setDirectTransferDemandId(null);additional.setIsFinal(false);split.add(additional);
            DailyReportOutputAllocationService.distributeWeight(line,split);expanded.addAll(split);
        }
        return expanded;
    }
    public void releaseClaims(UUID reportId) {
        db.update("""
                INSERT INTO production_actual_output_supplement_claims(proof_id,report_id,event_type,source_claim_id,created_by)
                SELECT proof_id,report_id,'RELEASE',id,:actor FROM production_actual_output_supplement_claims claim
                WHERE report_id=:report AND event_type='CLAIM'
                  AND NOT EXISTS(SELECT 1 FROM production_actual_output_supplement_claims release WHERE release.source_claim_id=claim.id)
                """,args("report",reportId,"actor",user.requireId()));
    }
    private Map<String,Object> context(UUID segment,boolean lock) {
        return one("""
                SELECT segment.*,plan.bill_no AS plan_no,plan.maker_id AS plan_maker_id,package.warehouse_id,
                       item.product_no,goods.name AS goods_name,goods.code AS goods_code,goods.spec AS goods_spec,
                       color.name AS color_name,unit.name AS unit_name,department.name AS workshop_name
                FROM production_execution_segments segment JOIN production_plans plan ON plan.id=segment.plan_id
                JOIN production_planning_packages package ON package.id=segment.package_id
                JOIN production_plan_items item ON item.id=segment.source_plan_item_id
                JOIN goods ON goods.id=segment.product_goods_id
                LEFT JOIN colors color ON color.id=segment.product_color_id LEFT JOIN units unit ON unit.id=segment.product_unit_id
                LEFT JOIN departments department ON department.id=segment.workshop_department_id
                WHERE segment.id=:id
                """+(lock?" AND NOT segment.is_deleted AND NOT plan.is_deleted AND plan.status=1 AND NOT plan.is_canceled AND NOT plan.is_stopped AND package.status='CONFIRMED' AND NOT package.is_deleted AND segment.status IN('IN_PROGRESS','COMPLETED') FOR UPDATE OF segment":""),args("id",segment));
    }
    private com.uten.imp.features.production.dailyreport.dto.ReportablePlanLine sourceLine(Map<String,Object> request) {
        return sourceLine(request,null);
    }
    private com.uten.imp.features.production.dailyreport.dto.ReportablePlanLine sourceLine(Map<String,Object> request,UUID recoveryId) {
        var c=context(uuid(request,"source_execution_segment_id"),false);
        var allocations=db.queryForList("""
                SELECT allocation.sales_order_item_id,allocation.allocated_qty,order_header.bill_no AS order_no,item.qty AS order_qty,client.name AS client_name
                FROM execution_segment_sales_allocations allocation JOIN sales_order_items item ON item.id=allocation.sales_order_item_id
                JOIN sales_orders order_header ON order_header.id=item.order_id LEFT JOIN clients client ON client.id=order_header.client_id
                WHERE allocation.id=:id AND allocation.execution_segment_id=:segment
                """,args("id",uuid(request,"source_sales_allocation_id"),"segment",uuid(c,"id")));
        if(uuid(request,"source_sales_allocation_id")!=null && allocations.size()!=1)throw invalid("原输入的销售分摊与执行工单不一致");
        Map<String,Object> a=allocations.isEmpty()?Map.of():allocations.getFirst();
        Map<String,Object> recovery=Map.of();
        if(recoveryId!=null) {
            var records=db.queryForList("""
                    SELECT authorization_row.disposition_code,authorization_row.source_inspection_id,
                           authorization_row.source_report_item_id,source_report.bill_no AS source_report_no,
                           CASE WHEN balance.cancelled THEN 0 ELSE balance.available_qty END AS available_qty,
                           authorization_row.disposition_code IN ('SCRAP','REJECT')
                             AND NOT fn_fqc_replenishment_material_ready(authorization_row.id) AS requires_material
                    FROM production_fqc_recovery_authorizations authorization_row
                    JOIN v_production_fqc_recovery_balance balance ON balance.authorization_id=authorization_row.id
                    JOIN production_daily_report_items source_item ON source_item.id=authorization_row.source_report_item_id
                    JOIN production_daily_reports source_report ON source_report.id=source_item.report_id
                    WHERE authorization_row.id=:id AND authorization_row.execution_segment_id=:segment
                      AND authorization_row.execution_segment_sales_allocation_id IS NOT DISTINCT FROM CAST(:allocation AS uuid)
                    """,args("id",recoveryId,"segment",uuid(c,"id"),"allocation",uuid(request,"source_sales_allocation_id")));
            if(records.size()!=1)throw invalid("原输入的品质恢复授权与执行工单不一致");
            recovery=records.getFirst();
        }
        BigDecimal planned=number(request,"source_planned_qty"),rate=number(c,"allowed_overproduction_rate");
        return new com.uten.imp.features.production.dailyreport.dto.ReportablePlanLine(
                uuid(c,"source_plan_item_id"),uuid(c,"id"),uuid(request,"source_sales_allocation_id"),Objects.toString(c.get("segment_code")),Objects.toString(c.get("status")),((Number)c.get("lock_version")).longValue(),
                uuid(a,"sales_order_item_id"),Objects.toString(c.get("plan_no")),Objects.toString(c.get("product_no"),null),uuid(c,"product_goods_id"),Objects.toString(c.get("goods_code"),null),Objects.toString(c.get("goods_name"),null),Objects.toString(c.get("goods_spec"),null),
                uuid(c,"product_color_id"),Objects.toString(c.get("color_name"),null),uuid(c,"product_unit_id"),Objects.toString(c.get("unit_name"),null),number(c,"product_unit_rate"),
                planned,number(request,"prior_reported_qty"),number(request,"original_report_qty"),number(a,"allocated_qty"),BigDecimal.ZERO,
                recoveryId==null?number(request,"original_report_qty"):number(recovery,"available_qty"),
                Objects.toString(a.get("order_no"),null),number(a,"order_qty"),Objects.toString(a.get("client_name"),null),uuid(c,"workshop_department_id"),Objects.toString(c.get("workshop_name"),null),
                null,null,null,recoveryId,Objects.toString(recovery.get("disposition_code"),null),number(recovery,"available_qty"),
                uuid(recovery,"source_inspection_id"),uuid(recovery,"source_report_item_id"),Objects.toString(recovery.get("source_report_no"),null),
                Boolean.TRUE.equals(recovery.get("requires_material")),uuid(c,"plan_id"),recoveryId==null,
                rate,planned.multiply(BigDecimal.ONE.add(rate)).setScale(4,RoundingMode.DOWN),BigDecimal.ZERO);
    }
    /** Identity metadata for the authorized captured input, independent of current free quota. */
    private List<InputSource> inputSources(com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest input) {
        if(input==null)return List.of();
        List<InputSource> result=new ArrayList<>();
        for(int index=0;index<input.getItems().size();index++) {
            var line=input.getItems().get(index);var source=context(line.getExecutionSegmentId(),false);
            requireSourceAccess(source);
            var metadata=sourceLine(args("source_execution_segment_id",line.getExecutionSegmentId(),
                    "source_sales_allocation_id",line.getExecutionSegmentSalesAllocationId(),
                    "source_planned_qty",number(source,"planned_qty"),"prior_reported_qty",BigDecimal.ZERO,
                    "original_report_qty",line.getQty()),line.getFqcRecoveryAuthorizationId());
            if(!Objects.equals(metadata.planItemId(),line.getPlanItemId()) || !Objects.equals(metadata.orderItemId(),line.getSalesOrderItemId())
                    || !Objects.equals(metadata.goodsId(),line.getGoodsId()) || !Objects.equals(metadata.colorId(),line.getColorId())
                    || !Objects.equals(metadata.unitId(),line.getUnitId())
                    || (line.getUnitRate()!=null && metadata.unitRate().compareTo(line.getUnitRate())!=0))
                throw conflict("申请时输入的来源身份需要重新核对");
            result.add(new InputSource(index,metadata));
        }
        return List.copyOf(result);
    }
    private Map<String,Object> request(UUID id,boolean lock) {
        return one("SELECT request.*,plan.bill_no AS plan_no,plan.maker_id AS plan_maker_id FROM production_actual_output_supplement_requests request JOIN production_plans plan ON plan.id=request.supplement_plan_id WHERE request.id=:id"+(lock?" FOR UPDATE OF request":""),args("id",id));
    }
    private com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest authorizedReportContext(Map<String,Object> request) {
        if(request.get("report_context")==null || (!Objects.equals(request.get("created_by"),user.requireId())&&!access.hasAuthority("production_plan:approve")))return null;
        var restored=readContext(request.get("report_context").toString());
        try {
            for(var line:restored.getItems())requireSourceAccess(context(line.getExecutionSegmentId(),false));
        } catch(ApiException denied) {return null;}
        return restored;
    }
    private void requireSourceAccess(Map<String,Object> context) {
        if(access.hasAuthority("production_plan:approve")){access.requireReadable(uuid(context,"plan_maker_id"),"生产工单不存在","production_plan:approve");return;}
        if(!membership.isWorkshopMember(uuid(context,"workshop_department_id"),uuid(context,"responsible_employee_id"),user.requireEmployeeId()))
            throw new ApiException(ErrorCode.FORBIDDEN,"只能办理本人所属或管理车间的实际产出追加");
    }
    private void lockCommand(String key){db.queryForObject("SELECT pg_advisory_xact_lock(hashtextextended(:key,700))",args("key","ACTUAL-SUPPLEMENT:"+user.requireId()+":"+key),Object.class);}
    private Map<String,Object> one(String sql,Map<String,Object> params){var rows=db.queryForList(sql,params);if(rows.size()!=1)throw conflict("追加计划或原生产来源不存在、已失效，请刷新后核对");return rows.getFirst();}
    private static UUID uuid(Map<String,Object> row,String key){return (UUID)row.get(key);}
    private static BigDecimal number(Map<String,Object> row,String key){Object value=row.get(key);return value==null?BigDecimal.ZERO:new BigDecimal(value.toString());}
    private static Map<String,Object> args(Object... values){Map<String,Object> result=new HashMap<>();for(int i=0;i<values.length;i+=2)result.put((String)values[i],values[i+1]);return result;}
    private static String hash(String source){try{return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(source.getBytes(StandardCharsets.UTF_8)));}catch(Exception error){throw new IllegalStateException(error);}}
    private String json(Object value){if(value==null)return null;try{return mapper.writeValueAsString(value);}catch(Exception error){throw new IllegalStateException(error);}}
    private com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest readContext(String value){try{return mapper.readValue(value,com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest.class);}catch(Exception error){throw conflict("追加计划的原批次快照损坏，请核对原申请");}}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
}
