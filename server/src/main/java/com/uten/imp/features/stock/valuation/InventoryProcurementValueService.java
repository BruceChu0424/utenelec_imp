package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.InventoryPositionPort;
import com.uten.imp.application.port.InventoryProcurementValuePort;
import com.uten.imp.application.port.InventoryValuationPort.State;
import com.uten.imp.application.port.ProcurementReceiptConsiderationPort;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import java.util.*;
import static com.uten.imp.features.stock.valuation.ValueMath.*;

/** Exact UUID resolver; financial amounts/styles remain their original approval authority. */
@Service
public class InventoryProcurementValueService implements InventoryProcurementValuePort {
    private final NamedParameterJdbcTemplate db;
    private final Optional<ProcurementReceiptConsiderationPort> consideration;
    private final InventoryPositionPort positions;
    public InventoryProcurementValueService(NamedParameterJdbcTemplate db,
            Optional<ProcurementReceiptConsiderationPort> consideration,InventoryPositionPort positions){
        this.db=db;this.consideration=consideration;this.positions=positions;
    }

    @Override @Transactional(propagation=Propagation.MANDATORY,readOnly=true)
    public FailureValue resolveFailure(FailureReference ref){
        if(ref==null||ref.failureCaseId()==null||ref.qualityPartId()==null||ref.fundingSliceId()==null||ref.sourceApLedgerId()==null)
            throw invalid("必须提供失败案件、品质切片、资金切片和原应付的完整UUID");
        ProcurementReceiptConsiderationPort port=consideration.orElseThrow(()->conflict("采购资金来源尚未接入，不能推测失败费用位置"));
        var matches=port.failure(ref.failureCaseId()).stream().filter(p->ref.fundingSliceId().equals(p.fundingSliceId())).toList();
        if(matches.size()!=1)throw conflict("资金切片不属于本次有效失败案件");
        var part=matches.getFirst();
        UUID ap=part.carriedFundingApId()!=null?part.carriedFundingApId():part.payableApId();
        var quality=port.failureQuality(ref.failureCaseId(),ref.fundingSliceId()).orElseThrow(()->conflict("失败资金尚无准确的品质事件关联"));
        if(!ref.sourceApLedgerId().equals(ap)||!ref.qualityPartId().equals(quality.id())
                ||!part.id().equals(quality.considerationPartId())||!"FAIL".equals(quality.action()))
            throw conflict("原应付、资金和失败品质切片不匹配");
        List<Map<String,Object>> rows=db.queryForList("""
                SELECT acquisition.source_node_id,failed.id failed_position_id
                FROM stock_value_acquisition_sources acquisition
                JOIN stock_value_events acquired ON acquired.id=acquisition.event_id
                JOIN stock_value_position_transfers transfer ON transfer.source_slice_id=:quality
                JOIN stock_value_events decision ON decision.id=transfer.event_id
                JOIN stock_value_nodes failed ON failed.id=transfer.target_node_id
                WHERE acquisition.evidence_id=:part AND decision.operation='POSITION_MOVE'
                  AND (transfer.source_root_id=acquired.result_node_id OR
                      (decision.source_doc_type='PROCUREMENT_QUALITY' AND decision.source_item_id=:quality
                          AND failed.owner_id=:quality))
                  AND failed.kind='ISSUE_POSITION' AND failed.root_issue_id=failed.id
                  AND failed.owner_kind='REJECTED_HOLD' AND failed.quantity_basis=:qty AND transfer.qty_base=:qty
                """,Map.of("quality",quality.id(),"part",part.id(),"qty",quality.baseQty()));
        if(rows.isEmpty())return new FailureValue(ref,part.id(),null,null,null,null,null,State.LEGACY_UNVERIFIED);
        if(rows.size()!=1)throw conflict("失败费用位置存在重复关联，必须先核对原品质切片");
        UUID root=(UUID)rows.getFirst().get("failed_position_id");var position=positions.position(root);
        return new FailureValue(ref,part.id(),root,(UUID)rows.getFirst().get("source_node_id"),position.pool(),
                position.remainingQtyBase(),position.knownValueLocal(),position.state());
    }
}
