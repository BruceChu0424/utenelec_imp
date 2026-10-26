package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.GoodsActualCostQueryPort.*;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.*;
import java.util.function.Consumer;

import static com.uten.imp.features.stock.valuation.GoodsActualCostQueryService.*;

/** The existing nullable valuation read equations, shared by materialized UI and streaming files. */
final class ActualCostEvidenceMath {
    static final String CURRENCY="LOCAL", PERIOD="PHYSICAL_OUTPUT_BUSINESS_DATE", INPUT_SCOPE="FULL_ORIGINAL_COST_OBJECT";
    private final List<Map<String,Object>> rows;
    private final Map<UUID,InputTotals> inputs=new HashMap<>();
    private final Consumer<Gap> gapConsumer;
    final List<Gap> baseGaps=new ArrayList<>(), objectGaps=new ArrayList<>();
    long inputCount,outputCount,gapCount,pendingSourceCount;
    private BigDecimal outputQty,outputAmount;
    private boolean outputPending;
    private List<CostObject> objects;
    private Summary summary;

    ActualCostEvidenceMath(List<Map<String,Object>> rows,UUID goodsId,Consumer<Gap> gapConsumer) {
        this.rows=rows;this.gapConsumer=gapConsumer;
        base(new Gap("LABOR_ACTUAL_NOT_LINKED",null,null,"LABOR"));
        base(new Gap("OVERHEAD_ACTUAL_NOT_LINKED",null,null,"OVERHEAD"));
        if(rows.isEmpty()) base(new Gap("NO_VALUATION_EVIDENCE",null,goodsId,"INVENTORY_PRODUCTION_COST"));
    }
    private void base(Gap gap){baseGaps.add(gap);recordGap(gap);}
    private void recordGap(Gap gap){gapCount++;if(gapConsumer!=null)gapConsumer.accept(gap);}
    static List<Gap> inputGaps(InputLine line) {
        List<Gap> result=new ArrayList<>(2);
        if(line.goodsCode()==null||line.goodsName()==null||line.unitId()==null||line.unitName()==null)
            result.add(new Gap("ORIGINAL_INPUT_IDENTITY_MISSING",line.costObjectId(),line.inputNodeId(),"IDENTITY"));
        if(line.grossQtyBase()==null||line.returnedQtyBase()==null||line.knownAmountLocal()==null)
            result.add(new Gap("INPUT_REVISION_EVIDENCE_MISSING",line.costObjectId(),line.inputNodeId(),"INVENTORY_PRODUCTION_COST"));
        return result;
    }
    void accept(InputLine line) {
        inputCount++; if(line.pending())pendingSourceCount++;
        inputs.computeIfAbsent(line.costObjectId(),ignored->new InputTotals()).accept(line);
        inputGaps(line).forEach(this::recordGap);
    }
    void accept(OutputLine line) {
        outputCount++;outputQty=add(outputQty,line.effectiveQtyBase());outputAmount=add(outputAmount,line.knownAmountLocal());
        outputPending|=line.pending();
    }
    void finish(UUID goodsId) {
        if(rows.isEmpty()) {
            objects=List.of();summary=new Summary(null,null,null,null,null,null,null,null,null,true,false,"INVENTORY_PRODUCTION_COST_ONLY",0);
            return;
        }
        List<CostObject> result=new ArrayList<>(rows.size());
        for(var row:rows) {
            UUID id=uuid(row,"cost_object_id");InputTotals own=inputs.getOrDefault(id,new InputTotals());
            BigDecimal known=own.known,allocated=own.allocated,target=decimal(row,"target_qty_base");
            BigDecimal held=known==null||allocated==null?null:known.subtract(allocated).max(BigDecimal.ZERO);
            BigDecimal adjustment=known==null||allocated==null?null:known.subtract(allocated).min(BigDecimal.ZERO);
            List<String> reasons=new ArrayList<>();
            if(uuid(row,"revision_id")==null)reasons.add("NO_APPROVED_COST_REVISION");
            if(number(row,"pending_tasks")>0)reasons.add("ALLOCATION_APPLYING");
            if(!bool(row,"historical")&&(bool(row,"business_refresh_pending")||bool(row,"dirty")||bool(row,"value_work_pending")))reasons.add("SOURCE_REFRESH_PENDING");
            if(!bool(row,"historical")&&!"FINAL".equals(text(row,"state")))reasons.add("COST_STATE_"+text(row,"state"));
            if(!bool(row,"scope_complete"))reasons.add("SCOPE_NOT_COMPLETE");
            BigDecimal revisionOutput=decimal(row,"output_qty_base");
            if(target==null||target.signum()<=0||revisionOutput==null||revisionOutput.compareTo(target)>0)reasons.add("OUTPUT_BASIS_PENDING");
            if(own.count==0)reasons.add("NO_INPUT_COST_EVIDENCE");
            if(own.pending)reasons.add("INPUT_COST_PENDING");
            String state=reasons.contains("ALLOCATION_APPLYING")||reasons.contains("SOURCE_REFRESH_PENDING")?"APPLYING":reasons.contains("OUTPUT_BASIS_PENDING")?"PENDING_BASIS":reasons.contains("COST_STATE_PENDING_CLASSIFICATION")?"PENDING_CLASSIFICATION":reasons.isEmpty()?"FINAL":"PROVISIONAL";
            result.add(new CostObject(id,text(row,"source_kind"),"PRODUCTION_EXECUTION".equals(text(row,"source_kind"))?id:null,text(row,"execution_no"),uuid(row,"revision_id"),number(row,"revision_version"),state,target,decimal(row,"output_qty_base"),known,allocated,target!=null&&target.signum()>0?held:BigDecimal.ZERO,adjustment,target==null||target.signum()==0?held:BigDecimal.ZERO,!reasons.isEmpty(),bool(row,"historical"),List.copyOf(reasons)));
            for(String reason:reasons){Gap gap=new Gap(reason,id,uuid(row,"revision_id"),"INVENTORY_PRODUCTION_COST");objectGaps.add(gap);recordGap(gap);}
        }
        objects=List.copyOf(result);
        BigDecimal scopeAllocated=sumNullable(objects.stream().map(CostObject::allocatedOutputCostLocal).toList());
        boolean pending=objects.stream().anyMatch(CostObject::pending)||outputPending||outputCount==0;
        BigDecimal unit=!pending&&outputAmount!=null&&outputQty!=null&&outputQty.signum()>0?outputAmount.divide(outputQty,12,RoundingMode.HALF_UP):null;
        summary=new Summary(sumNullable(objects.stream().map(CostObject::knownInputCostLocal).toList()),outputCount==0?null:outputAmount,
                scopeAllocated,scopeAllocated==null||outputAmount==null?null:scopeAllocated.subtract(outputAmount),
                sumNullable(objects.stream().map(CostObject::heldWipLocal).toList()),sumNullable(objects.stream().map(CostObject::pendingReallocationLocal).toList()),
                sumNullable(objects.stream().map(CostObject::unclassifiedLocal).toList()),outputQty,unit,pending,false,"INVENTORY_PRODUCTION_COST_ONLY",pendingSourceCount);
    }
    List<CostObject> objects(){return objects;}
    Summary summary(){return summary;}
    private static BigDecimal add(BigDecimal current,BigDecimal value){return value==null?current:current==null?value:current.add(value);}
    private static final class InputTotals {
        long count;BigDecimal known,allocated;boolean pending;
        void accept(InputLine line){count++;known=add(known,line.knownAmountLocal());allocated=add(allocated,line.allocatedAmountLocal());pending|=line.pending();}
    }
}
