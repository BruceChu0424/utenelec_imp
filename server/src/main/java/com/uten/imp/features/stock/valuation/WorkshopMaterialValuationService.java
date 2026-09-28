package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.InventoryMovementCostReference.WorkshopMaterialBin;
import com.uten.imp.application.port.InventoryValuationPort;
import com.uten.imp.application.port.InventoryValuationPort.*;
import com.uten.imp.features.stock.StockService.MovementRequest;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.*;
import static com.uten.imp.features.stock.valuation.ValueMath.*;

/**
 * 车间内料仓盘点过账的估价(ADR-131 §4.6)。只认本事务登记的盘点过账行, 调用方不带单价:
 * <ul>
 *   <li>21 型出(盘点耗用): 按池均价出到在制, 去向 = 期间用量行; 记车间费用的料出到外部;</li>
 *   <li>21 型入(耗用冲回): 原路退回被冲那笔 21 型出库的价值区间;</li>
 *   <li>22 型入(盘盈): 已知成本入库, 单价依次取内料仓池当时已知均价、最近一次调入这种料的单价,
 *       都没有按 0 核定(结算时在报表标红), 不留"成本未定";</li>
 *   <li>22 型出(盘盈冲回): 按出库时池均价出到外部, 与盘盈入库同一对手方。平均池对普通入库没有
 *       按原值撤回的接口(ReverseStore 只适用于经 store 建立的入库), 差额在报表可见。</li>
 * </ul>
 * 期间用量行上的分摊方式是提交盘点时的快照, 估价只认它, 不读货品当前设置。
 */
@Service
@Transactional(propagation=Propagation.MANDATORY)
public class WorkshopMaterialValuationService {
    private final NamedParameterJdbcTemplate db;
    private final InventoryValuationPort values;
    public WorkshopMaterialValuationService(NamedParameterJdbcTemplate db,InventoryValuationPort values){
        this.db=db;this.values=values;
    }

    public MovementValue value(UUID movement,MovementRequest request,PoolKey pool,BigDecimal before,
            EventContext context,WorkshopMaterialBin ref){
        Map<String,Object> args=new HashMap<>();
        args.put("posting",ref.sourceId());args.put("count",request.sourceDocId());args.put("line",request.sourceItemId());
        args.put("bin",pool.warehouseId());args.put("goods",pool.goodsId());args.put("color",pool.colorId());
        var rows=db.queryForList("""
                SELECT posting.kind,posting.qty,line.cost_basis,
                       reversed.kind AS reversed_kind,reversed.movement_id AS reversed_movement_id
                FROM workshop_material_count_postings posting
                JOIN workshop_material_period_lines line ON line.id=posting.period_line_id
                LEFT JOIN workshop_material_count_postings reversed ON reversed.id=posting.reverses_posting_id
                WHERE posting.id=:posting AND posting.count_id=:count AND posting.period_line_id=:line
                  AND posting.bin_warehouse_id=:bin AND posting.goods_id=:goods
                  AND posting.color_id IS NOT DISTINCT FROM CAST(:color AS uuid)
                """,args);
        if(rows.size()!=1)throw conflict("内料仓盘点过账缺少本次登记的来源，请刷新后重试");
        var row=rows.getFirst();
        if(!ref.kind().name().equals(row.get("kind"))||((BigDecimal)row.get("qty")).compareTo(request.qty())!=0)
            throw conflict("内料仓盘点过账与本次库存流水的种类或数量不一致");
        UUID periodLine=request.sourceItemId();
        return switch(ref.kind()){
            case CONSUME -> values.issue(new Issue(context,movement,pool,request.qty(),before,
                    "EXPENSE".equals(row.get("cost_basis"))?Destination.EXTERNAL:Destination.WIP,periodLine));
            case CONSUME_REVERSE -> values.returnIssue(new ReturnIssue(context,movement,pool,request.qty(),before,
                    originalIssue(row,"CONSUME")));
            case GAIN -> values.receive(new Receive(context,movement,pool,request.qty(),before,
                    gainCost(pool,request.qty()),true));
            case GAIN_REVERSE -> {
                requireReversed(row,"GAIN");
                yield values.issue(new Issue(context,movement,pool,request.qty(),before,Destination.EXTERNAL,periodLine));
            }
            case ISSUE_OUT,RETURN_OUT,OTHER_ISSUE_OUT -> throw conflict("内料仓的发料、退回和其它耗用按库存单据估价");
        };
    }

    /** 被冲那笔盘点耗用出库时冻结的价值区间, 冲回只能原路退回它。 */
    private UUID originalIssue(Map<String,Object> row,String reversedKind){
        requireReversed(row,reversedKind);
        var roots=db.queryForList("SELECT result_node_id FROM stock_value_events WHERE movement_id=:movement AND operation='ISSUE'",
                Map.of("movement",row.get("reversed_movement_id")),UUID.class);
        if(roots.size()!=1)throw conflict("冲回缺少原盘点耗用的实际成本，请核对原过账");
        return roots.getFirst();
    }

    private static void requireReversed(Map<String,Object> row,String reversedKind){
        if(!reversedKind.equals(row.get("reversed_kind"))||row.get("reversed_movement_id")==null)
            throw conflict("盘点过账的冲回必须指向同一期已经入账的同类过账");
    }

    /** 盘盈核定价: 池当时已知均价 → 最近一次调入这种料的单价 → 0(不留成本未定)。 */
    private BigDecimal gainCost(PoolKey pool,BigDecimal qty){
        PoolValue current=values.pool(pool);
        if(current.state()==State.FINAL&&current.knownValueLocal()!=null
                &&current.qtyBase()!=null&&current.qtyBase().signum()>0)
            return share(current.knownValueLocal(),qty,current.qtyBase());
        Map<String,Object> args=new HashMap<>();
        args.put("bin",pool.warehouseId());args.put("goods",pool.goodsId());args.put("color",pool.colorId());
        var recent=db.queryForList("""
                SELECT movement.amount_local,movement.qty
                FROM stock_movements movement
                JOIN stock_value_events event ON event.movement_id=movement.id AND event.result_state='FINAL'
                WHERE movement.warehouse_id=:bin AND movement.goods_id=:goods
                  AND movement.color_id IS NOT DISTINCT FROM CAST(:color AS uuid)
                  AND movement.movement_type=7 AND movement.direction=1
                  AND movement.qty>0 AND movement.amount_local IS NOT NULL
                ORDER BY movement.transaction_date DESC,movement.created_at DESC,movement.id DESC
                LIMIT 1
                """,args);
        if(recent.isEmpty())return ZERO;
        return share((BigDecimal)recent.getFirst().get("amount_local"),qty,(BigDecimal)recent.getFirst().get("qty"));
    }

    /** 已知总额按数量取份额, 4 位(与库存估值切片同一口径)。 */
    private static BigDecimal share(BigDecimal value,BigDecimal qty,BigDecimal basis){
        return value.multiply(qty).divide(basis,4,RoundingMode.HALF_UP);
    }
}
