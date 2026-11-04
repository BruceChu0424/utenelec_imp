package com.uten.imp.common.finance;

import com.uten.imp.application.port.BusinessNumericInputEvidencePort;
import com.uten.imp.application.port.BusinessNumericInputEvidencePort.Capture;
import com.uten.imp.application.port.BusinessNumericInputEvidencePort.Unit;
import com.uten.imp.common.integrity.SourceQuantityBasis;
import com.uten.imp.common.util.NativeValueConverters;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import java.math.BigDecimal;
import java.util.*;

/** One adopted quantity and its original operands. The owning document must
 * authorize and lock before using this internal, amount-free entry point. */
public final class DocumentUnitConversion {
    private DocumentUnitConversion() { }
    public record Projection(BigDecimal quantity,BigDecimal rate,BigDecimal product,BigDecimal basicQuantity,
                             Map<String,BusinessPrecisionContext.Choice> policy){ }
    public record OriginalMovement(UUID id,BigDecimal quantity){ }
    public static Projection project(BigDecimal quantity,UUID unitId,BigDecimal rate){
        SourceQuantityBasis.requireKnown(unitId,rate);
        BigDecimal basic=MoneyPolicy.quantityToBase(quantity,rate);
        BigDecimal product=quantity.stripTrailingZeros().multiply(rate.stripTrailingZeros());
        var choice=product.stripTrailingZeros().scale()>24?BusinessPrecisionContext.usedChoices().get("quantity.to-base"):null;
        return new Projection(quantity,rate,product,basic,
                choice==null?Map.of():Map.of("quantity.to-base",choice));
    }
    public static void requireWithin(Projection value,BigDecimal available){
        if(available==null||available.signum()<0)throw new ApiException(ErrorCode.CONFLICT,"原来源实际数量容量尚未核对");
        if(value.basicQuantity().compareTo(available)<=0)return;
        if(!value.policy().isEmpty())throw new BusinessPrecisionRequiredException("quantity.to-base","本次基本单位数量换算：所选精度超过原来源容量，请明确重新选择",24,"PRECISION_LIMIT",true);
        throw new ApiException(ErrorCode.CONFLICT,"本次数量超过原来源实际可用数量");
    }
    public static OriginalMovement originalMovement(EntityManager em,String family,int type,UUID document,UUID item,
                                                    UUID goods,UUID color,UUID warehouse,int direction){
        @SuppressWarnings("unchecked") List<Object[]> rows=em.createNativeQuery("""
                SELECT id,qty FROM stock_movements WHERE source_doc_type=:family AND movement_type=:type
                  AND source_doc_id=:document AND source_item_id=:item AND goods_id=:goods
                  AND color_id IS NOT DISTINCT FROM CAST(:color AS uuid) AND warehouse_id=:warehouse AND direction=:direction
                ORDER BY ledger_seq
                """).setParameter("family",family).setParameter("type",type).setParameter("document",document)
                .setParameter("item",item).setParameter("goods",goods).setParameter("color",color).setParameter("warehouse",warehouse)
                .setParameter("direction",direction).getResultList();
        if(rows.size()!=1)throw new ApiException(ErrorCode.CONFLICT,"反向缺少同源、同仓的唯一原实物数量记录，不能按当前输入或新精度推算");
        return new OriginalMovement(NativeValueConverters.uuid(rows.getFirst()[0]),NativeValueConverters.toBigDecimal(rows.getFirst()[1]));
    }
    public static void capture(BusinessNumericInputEvidencePort evidence,UUID movement,UUID item,UUID goods,UUID unitId,Projection value){
        if(evidence==null)throw new ApiException(ErrorCode.CONFLICT,"当前无法保存原数量换算依据，请保留输入");
        Unit line=new Unit("LINE_QUANTITY",null,unitId),base=new Unit("GOODS_BASE",null,goods),rate=new Unit("RATIO","BASE_PER_LINE",unitId);
        evidence.record(new Capture("STOCK_MOVEMENT",movement,item,"rawQuantity","1",value.quantity(),line,value.quantity(),line,Map.of()));
        evidence.record(new Capture("STOCK_MOVEMENT",movement,item,"rawUnitRate","1",value.rate(),rate,value.rate(),rate,Map.of()));
        evidence.record(new Capture("STOCK_MOVEMENT",movement,item,"basicQuantity","1",value.product(),base,value.basicQuantity(),base,value.policy()));
    }
    /** Approval consumes the adoption frozen with the saved detail, not a newly selected rounding. */
    public static Projection saved(EntityManager em,UUID item,BigDecimal quantity,UUID unitId,BigDecimal rate){return saved(em,"subcontract_material_return_items",item,quantity,unitId,rate);}
    public static Projection saved(EntityManager em,String table,UUID item,BigDecimal quantity,UUID unitId,BigDecimal rate){
        if(!Set.of("subcontract_material_return_items","subcontract_receipt_items","sales_shipment_items").contains(table))throw new IllegalArgumentException("Unknown quantity owner");
        SourceQuantityBasis.requireKnown(unitId,rate);
        Object value=em.createNativeQuery("SELECT to_jsonb(i)->>'adopted_base_qty' FROM "+table+" i WHERE id=:id")
                .setParameter("id",item).getSingleResult();
        BigDecimal product=quantity.stripTrailingZeros().multiply(rate.stripTrailingZeros());
        BigDecimal basic=value==null?com.uten.imp.common.util.FinancialExactAmount.quantity(product,"原未采用基本数量"):
                com.uten.imp.common.util.FinancialExactAmount.quantity(new BigDecimal(value.toString()),"原已采用基本数量");
        return new Projection(quantity,rate,product,basic,Map.of());
    }
    public static void captureSaved(BusinessNumericInputEvidencePort evidence,UUID movement,UUID item,UUID goods,UUID unitId,Projection value){
        if(evidence==null)throw new ApiException(ErrorCode.CONFLICT,"当前无法保存原数量换算依据，请保留输入");
        Unit line=new Unit("LINE_QUANTITY",null,unitId),rate=new Unit("RATIO","BASE_PER_LINE",unitId);
        evidence.record(new Capture("STOCK_MOVEMENT",movement,item,"rawQuantity","1",value.quantity(),line,value.quantity(),line,Map.of()));
        evidence.record(new Capture("STOCK_MOVEMENT",movement,item,"rawUnitRate","1",value.rate(),rate,value.rate(),rate,Map.of()));
        evidence.record(new Capture("STOCK_MOVEMENT",movement,item,"frozenBasicQuantity","1",value.basicQuantity(),
                new Unit("DOCUMENT_ADOPTED_QTY",null,item),value.basicQuantity(),new Unit("GOODS_BASE",null,goods),Map.of()));
    }
    public static void captureRestore(BusinessNumericInputEvidencePort evidence,UUID movement,UUID item,UUID goods,OriginalMovement original){
        if(evidence==null)throw new ApiException(ErrorCode.CONFLICT,"当前无法保存原实物数量反向依据，请保留输入");
        evidence.record(new Capture("STOCK_MOVEMENT",movement,item,"restoredBasicQuantity","1",original.quantity(),
                new Unit("STOCK_MOVEMENT_QTY",null,original.id()),original.quantity(),new Unit("GOODS_BASE",null,goods),Map.of()));
    }
}
