package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.dailyreport.dto.DailyReportMaterialUsageLine;
import com.uten.imp.features.production.execution.ProductionDrawRequest;
import com.uten.imp.features.production.execution.ProductionDrawRequestService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocIssueRequest;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import org.springframework.jdbc.core.JdbcTemplate;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Real input facts for supply/return fixtures whose old no-input premise is no longer valid. */
final class WorkshopMaterialFlowTestSupport {
    private WorkshopMaterialFlowTestSupport() {}

    static void receiveFreeInput(StockDocService stock,FullChainEndToEndTest.World world,UUID warehouse,UUID goods,BigDecimal qty){
        var request=new StockDocSaveRequest();request.setDocType("OTHER_IN");request.setWarehouseId(warehouse);request.setBillDate(BusinessTime.today());
        var item=new StockDocItemLine();item.setGoodsId(goods);item.setUnitId(world.unitId());item.setUnitRate(BigDecimal.ONE);item.setQty(qty);
        // The unvalued branch previously manufactured zero-cost output. Preserve that monetary premise,
        // while giving it a genuine, explicitly priced zero-cost material receipt and actual use.
        item.setPrice(BigDecimal.ZERO);item.setAmountOriginal(BigDecimal.ZERO);item.setAmountLocal(BigDecimal.ZERO);request.setItems(List.of(item));
        stock.approve(stock.create(request).getId());
    }

    static void issue(JdbcTemplate db,ProductionDrawRequestService draws,StockDocService stock,UUID segment){
        long version=db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?",Long.class,segment);
        var items=List.of(new ProductionDrawRequest.Item(segment,version));var preview=draws.preview(new ProductionDrawRequest.PreviewRequest(items));
        assertFalse(preview.lines().isEmpty(),"source manufacturing must have real material ready to issue");
        var submitted=draws.submit(new ProductionDrawRequest.SubmitRequest(items,"fixture-draw-"+UUID.randomUUID(),preview.fingerprint()));
        for(UUID document:submitted.documentIds()){
            var command=new StockDocIssueRequest();command.setIdempotencyKey("fixture-issue-"+UUID.randomUUID());
            command.setLines(preview.lines().stream().filter(row->document.equals(row.drawId())).map(row->{var line=new StockDocIssueRequest.Line();line.setItemId(row.drawItemId());line.setQty(row.qty());return line;}).toList());
            stock.approveAndIssue(document,command);
        }
    }

    static List<DailyReportMaterialUsageLine> materialUse(JdbcTemplate db,UUID segment,BigDecimal output){
        return db.query("""
                SELECT demand.id,demand.required_qty,segment.planned_qty,demand.requirement_mode,
                    EXISTS(SELECT 1 FROM production_material_stock_postings issue WHERE issue.demand_id=demand.id AND issue.posting_type='ISSUE')
                FROM production_material_demands demand JOIN production_execution_segments segment ON segment.id=demand.execution_segment_id
                WHERE segment.id=? AND NOT demand.is_deleted AND demand.status NOT IN('RELEASED','REVERSED')
                ORDER BY demand.id
                """,(row,index)->{
            assertTrue(List.of("LINEAR","EXACT_SNAPSHOT").contains(row.getString(4)),"this proportional fixture needs a frozen physical requirement");
            var line=new DailyReportMaterialUsageLine();line.setDemandId(row.getObject(1,UUID.class));
            line.setQtyBase(row.getBigDecimal(2).multiply(output).divide(row.getBigDecimal(3),4,RoundingMode.UP));
            assertTrue(row.getBoolean(5),"actual use must reference a real ISSUE");
            // Invalid over-report scenarios must reach the service's capacity guard, not fail in this fixture.
            return line;
        },segment);
    }
}
