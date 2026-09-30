package com.uten.imp.features.master.goods.costing;

import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.application.port.InventoryValuationPort;
import com.uten.imp.application.port.InventoryValueAuthorityPort;
import com.uten.imp.features.master.lifecycle.MasterObjectAccess;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.stereotype.Component;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;
import static com.uten.imp.features.master.goods.costing.GoodsCostContracts.*;
import static com.uten.imp.common.finance.CostCalculationMath.*;

/** Bounded, read-only source projections. A remembered draft price is deliberately not an approved candidate. */
@Component
@RequiredArgsConstructor
public class GoodsCostSourceReader {
    /** A bounded search stopped; callers may show this row as pending, never as proof that no price exists. */
    public static final class PriceSearchIncomplete extends RuntimeException {
        public PriceSearchIncomplete(String message){super(message);}
    }
    private final NamedParameterJdbcTemplate db;
    private final MasterReferenceValidationPort references;
    private final MasterObjectAccess access;
    private final InventoryValuationPort inventoryValues;
    private final InventoryValueAuthorityPort valueAuthority;
    public record GoodsInfo(UUID id,String code,String name,UUID unitId,String unitName,
            UUID colorId,String colorName,String sourceType,String revision) {}
    public record Edge(UUID id,UUID parentId,GoodsInfo goods,BigDecimal designQty,BigDecimal actualQty,
            BigDecimal effectiveQty,String actualStatus,long samples,BigDecimal output,BigDecimal net,
            String basis,BigDecimal basisOutput,boolean partial,boolean learned,String revision) {}
    public GoodsInfo goods(UUID id) {
        references.requireVisibleGoods(id);
        List<GoodsInfo> rows=db.query("""
                SELECT g.id,g.code,g.name,g.unit_id,u.name unit_name,g.color_id,c.name color_name,
                       g.source_type,g.version FROM goods g LEFT JOIN units u ON u.id=g.unit_id
                LEFT JOIN colors c ON c.id=g.color_id WHERE g.id=:id AND NOT g.is_deleted AND NOT g.auto_created
                """,Map.of("id",id),(r,n)->new GoodsInfo(r.getObject("id",UUID.class),r.getString("code"),
                r.getString("name"),r.getObject("unit_id",UUID.class),r.getString("unit_name"),
                r.getObject("color_id",UUID.class),r.getString("color_name"),r.getString("source_type"),r.getString("version")));
        if(rows.size()!=1) throw invalid("货品不存在或为历史占位货品");
        if(rows.getFirst().unitId()==null) throw invalid("货品未维护基本单位");
        return rows.getFirst();
    }
    public List<Edge> edges(UUID parent) {
        return db.query("""
                SELECT b.id,b.goods_id,b.component_goods_id,g.code,g.name,g.unit_id,u.name unit_name,
                       COALESCE(b.color_id,g.color_id) color_id,c.name color_name,g.source_type,g.version,
                       b.qty,b.consumption_basis,b.basis_output_qty,b.allow_partial_package,b.updated_at,
                       x.actual_qty,x.effective_qty,x.actual_status,x.sample_count,x.exposure_output_qty,x.net_qty,
                       x.system_learned
                FROM goods_bom_items b JOIN goods g ON g.id=b.component_goods_id
                LEFT JOIN units u ON u.id=g.unit_id LEFT JOIN colors c ON c.id=COALESCE(b.color_id,g.color_id)
                LEFT JOIN v_goods_bom_item_usage x ON x.bom_item_id=b.id
                WHERE b.goods_id=:id AND NOT b.is_deleted AND NOT g.is_deleted AND NOT g.auto_created
                ORDER BY b.sort_order,b.id
                """,Map.of("id",parent),(r,n)->new Edge(r.getObject("id",UUID.class),parent,
                new GoodsInfo(r.getObject("component_goods_id",UUID.class),r.getString("code"),r.getString("name"),
                r.getObject("unit_id",UUID.class),r.getString("unit_name"),r.getObject("color_id",UUID.class),
                r.getString("color_name"),r.getString("source_type"),r.getString("version")),r.getBigDecimal("qty"),
                r.getBigDecimal("actual_qty"),r.getBigDecimal("effective_qty"),r.getString("actual_status"),
                r.getLong("sample_count"),r.getBigDecimal("exposure_output_qty"),r.getBigDecimal("net_qty"),
                r.getString("consumption_basis"),r.getBigDecimal("basis_output_qty"),r.getBoolean("allow_partial_package"),
                r.getBoolean("system_learned"),Objects.toString(r.getObject("updated_at"),"")));
    }
    public String currency(UUID id) {
        if(id==null) return "本币";
        List<String> rows=db.queryForList("SELECT name FROM currencies WHERE id=:id AND NOT is_deleted",Map.of("id",id),String.class);
        if(rows.size()!=1) throw invalid("币种不存在或已删除");
        return rows.getFirst();
    }
    public boolean baseCurrency(UUID id) {
        if(id==null)return true;
        List<Boolean> rows=db.queryForList("SELECT is_base_currency FROM currencies WHERE id=:id AND NOT is_deleted",Map.of("id",id),Boolean.class);
        if(rows.size()!=1)throw invalid("币种不存在或已删除");
        return Boolean.TRUE.equals(rows.getFirst());
    }
    public PriceEvidence approved(GoodsInfo goods,boolean subcontract,LocalDate date,UUID explicitItem) {
        String kind=subcontract?"subcontract":"purchase";
        // Do not let one page of inaccessible/incomplete records hide an older reliable approved price.
        var parameters=new MapSqlParameterSource().addValue("goods",goods.id()).addValue("color",goods.colorId())
                .addValue("date",date).addValue("item",explicitItem==null?null:explicitItem.toString())
                .addValue("lastDate",null).addValue("lastTime",null).addValue("lastItem",null);
        var visible=access.readableLabelOwner(kind);
        for(int page=0;page<100;page++) {
            List<Map<String,Object>> rows=db.queryForList("""
                SELECT o.id,o.bill_no,o.bill_date,o.updated_at,o.supplier_id,o.currency_id,c.name currency_name,
                       o.exchange_rate,o.tax_rate,o.purchaser_id,i.id item_id,i.unit_id,u.name unit_name,
                       i.unit_rate,i.price,i.qty,i.amount_original,i.extra_columns,i.updated_at item_updated_at,
                       EXISTS(SELECT 1 FROM jsonb_array_elements(COALESCE(i.extra_columns,'[]'::jsonb)) adjustment
                              WHERE COALESCE(adjustment->>'operation','NONE')<>'NONE') adjustment_rules
                FROM %1$s_orders o JOIN %1$s_order_items i ON i.order_id=o.id
                LEFT JOIN currencies c ON c.id=o.currency_id LEFT JOIN units u ON u.id=i.unit_id
                WHERE o.status=1 AND NOT o.is_deleted AND NOT i.is_deleted
                  AND i.goods_id=:goods AND i.color_id IS NOT DISTINCT FROM CAST(:color AS uuid)
                  AND o.bill_date<=:date AND i.price IS NOT NULL AND i.price>=0
                  AND (CAST(:item AS uuid) IS NULL OR i.id=CAST(:item AS uuid))
                  AND (CAST(:lastDate AS date) IS NULL OR (o.bill_date,o.updated_at,i.id)
                       <(CAST(:lastDate AS date),CAST(:lastTime AS timestamptz),CAST(:lastItem AS uuid)))
                ORDER BY o.bill_date DESC,o.updated_at DESC,i.id DESC LIMIT 100
                """.formatted(kind),parameters);
        for(var row:rows) {
            if(!visible.test((UUID)row.get("purchaser_id"))) continue;
            UUID unit=(UUID)row.get("unit_id");
            BigDecimal unitRate=(BigDecimal)row.get("unit_rate");
            if(unitRate==null && Objects.equals(unit,goods.unitId())) unitRate=BigDecimal.ONE;
            BigDecimal fx=(BigDecimal)row.get("exchange_rate");
            if(unit==null || unitRate==null || unitRate.signum()<=0 || fx==null || fx.signum()<=0
                    || row.get("supplier_id")==null || row.get("currency_id")==null
                    || Objects.equals(unit,goods.unitId())&&unitRate.compareTo(BigDecimal.ONE)!=0) continue;
            BigDecimal sourceQty=(BigDecimal)row.get("qty"),sourceAmount=(BigDecimal)row.get("amount_original"),sourcePrice=(BigDecimal)row.get("price");
            boolean adjusted=Boolean.TRUE.equals(row.get("adjustment_rules"))||sourceQty==null||sourceQty.signum()<=0
                    ||sourceAmount==null||sourceAmount.compareTo(sourceQty.multiply(sourcePrice))!=0;
            String explanation=adjusted?"原单含独立计费项或金额依据待核对，不能把整行金额摊到不同批量；原单数量="+text(sourceQty)
                    +"，原单金额="+text(sourceAmount)+"。请拆分费用或人工复核采用成本。":"按已审核单据原记录价计成本；仅作单位和币种换算，不按税率自动扣税";
            return new PriceEvidence(subcontract?"APPROVED_SUBCONTRACT":"APPROVED_PURCHASE",(UUID)row.get("id"),
                    (UUID)row.get("item_id"),(String)row.get("bill_no"),priceRevision(row),
                    adjusted?"APPROVED_WITH_COMPONENTS":"APPROVED",(UUID)row.get("supplier_id"),(UUID)row.get("currency_id"),(String)row.get("currency_name"),
                    unit,(String)row.get("unit_name"),text(unitRate),text((BigDecimal)row.get("price")),text(fx),
                    text((BigDecimal)row.get("tax_rate")),"AS_RECORDED",row.get("bill_date") instanceof LocalDate d?d:((java.sql.Date)row.get("bill_date")).toLocalDate(),
                    explanation);
        }
            if(rows.size()<100)return null;
            Map<String,Object> last=rows.getLast();
            parameters.addValue("lastDate",last.get("bill_date")).addValue("lastTime",last.get("updated_at")).addValue("lastItem",last.get("item_id"));
        }
        throw new PriceSearchIncomplete("价格候选超过本次核对上限，尚未查完，请选择具体已审核来源或缩小成本日期");
    }
    private static String priceRevision(Map<String,Object> row) {
        StringBuilder value=new StringBuilder();
        for(String key:List.of("id","item_id","updated_at","item_updated_at","supplier_id","currency_id","exchange_rate","tax_rate","unit_id","unit_rate","price","qty","amount_original","extra_columns","bill_date")) {
            Object part=row.get(key);value.append(key).append('=')
                    .append(part instanceof BigDecimal decimal?text(decimal):Objects.toString(part,"NULL")).append('|');
        }
        try {return HexFormat.of().formatHex(java.security.MessageDigest.getInstance("SHA-256")
                .digest(value.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8)));}
        catch(java.security.NoSuchAlgorithmException impossible){throw new IllegalStateException(impossible);}
    }
    public PriceEvidence inventory(GoodsInfo goods,LocalDate date) {
        // An inventory reference is a present snapshot, not a reconstructed historical moving average.
        if(!com.uten.imp.common.time.BusinessTime.today().equals(date)) return null;
        var rows=db.queryForList("""
                SELECT b.warehouse_id,b.qty,b.amount_local
                FROM stock_balances b JOIN warehouses w ON w.id=b.warehouse_id AND w.is_accountable
                WHERE b.goods_id=:goods AND b.color_id IS NOT DISTINCT FROM CAST(:color AS uuid) AND b.qty>0
                ORDER BY b.warehouse_id LIMIT 501
                """,new MapSqlParameterSource().addValue("goods",goods.id()).addValue("color",goods.colorId()));
        if(rows.isEmpty()) return null;
        if(rows.size()>500)throw new PriceSearchIncomplete("库存参考来源超过本次核对上限，请选择明确的成本价格来源");
        BigDecimal qty=BigDecimal.ZERO,amount=BigDecimal.ZERO;
        List<String> revisions=new ArrayList<>();
        for(var row:rows) {
            // Reuse the formal publication fence and pool/balance reconciliation, including late-price jobs.
            var key=new InventoryValuationPort.PoolKey((UUID)row.get("warehouse_id"),goods.id(),goods.colorId());
            var pool=inventoryValues.pool(key);
            if(pool==null||pool.state()!=InventoryValuationPort.State.FINAL||pool.propagationPending()||pool.headNodeId()==null
                    ||pool.qtyBase()==null||pool.qtyBase().signum()<=0||pool.knownValueLocal()==null
                    ||pool.qtyBase().compareTo((BigDecimal)row.get("qty"))!=0||row.get("amount_local")==null
                    ||pool.knownValueLocal().compareTo((BigDecimal)row.get("amount_local"))!=0)return null;
            List<Long> versions=db.queryForList("SELECT revision FROM stock_value_nodes WHERE id=:id",Map.of("id",pool.headNodeId()),Long.class);
            if(versions.size()!=1)return null;
            var reference=new InventoryValueAuthorityPort.ValueReference(pool.headNodeId(),versions.getFirst());
            var authority=valueAuthority.authority(reference);
            if(authority==null||!authority.costComplete()||authority.readiness()!=InventoryValueAuthorityPort.Readiness.READY
                    ||authority.lowerKnownValue()==null||authority.upperKnownValue()==null)return null;
            qty=qty.add(pool.qtyBase());amount=amount.add(pool.knownValueLocal());
            revisions.add(pool.poolId()+":"+pool.headNodeId()+":"+versions.getFirst()+":"
                    +text(authority.lowerKnownValue())+":"+text(authority.upperKnownValue()));
        }
        return new PriceEvidence("INVENTORY_REFERENCE",goods.id(),null,null,String.join(",",revisions),
                "FINAL_REFERENCE",null,null,"本币",goods.unitId(),goods.unitName(),"1",text(divide(amount,qty)),"1",null,
                "AS_RECORDED",date,"当前已核定库存参考，已核对价值传播与精确来源：金额="+text(amount)+"；数量="+text(qty));
    }
}
