package com.uten.imp.features.sales.shipment;

import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.sales.shipment.dto.ShipmentSaveRequest;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/** Explicit customer pricing for an orderless dispatch, never inferred from a reference price. */
@Service
@RequiredArgsConstructor
@Transactional(propagation=Propagation.MANDATORY)
public class DirectCustomerShipmentCommercialService {
    private final EntityManager em;
    private final MasterReferenceValidationPort references;

    public void normalize(ShipmentSaveRequest request) {
        references.requireVisibleActiveClient(request.getClientId());
        String mode=request.getBillingMode()==null?"":request.getBillingMode().trim().toUpperCase(java.util.Locale.ROOT);
        String purpose=request.getDirectPurpose()==null?"":request.getDirectPurpose().trim().toUpperCase(java.util.Locale.ROOT);
        if(!Set.of(CustomerShipmentPolicy.CHARGED,CustomerShipmentPolicy.FREE).contains(mode))throw validation("请明确选择收费或不收费");
        if(!Set.of("SAMPLE","GIFT","OTHER").contains(purpose))throw validation("请选择客户发货用途");
        boolean free=CustomerShipmentPolicy.FREE.equals(mode);
        String reason=request.getFreeReason()==null?null:request.getFreeReason().trim();
        if(free&&(reason==null||reason.isEmpty()||reason.length()>500))throw validation("不收费发货须填写原因，最多500字");
        request.setBillingMode(mode);request.setDirectPurpose(purpose);request.setFreeReason(free?reason:null);
        if(free) {
            request.setSettlementMethodId(null);request.setPaymentStyleId(null);
            List<?> base=em.createNativeQuery("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted AND status='使用'").getResultList();
            if(base.size()!=1)throw validation("系统本位币尚未配置，请联系财务");
            request.setCurrencyId((UUID)base.getFirst());request.setTaxRate(BigDecimal.ZERO);
        } else if(request.getCurrencyId()==null)throw validation("收费发货请选择币种");
        request.setExchangeRate(null);
        if(request.getTaxRate()==null)request.setTaxRate(BigDecimal.ZERO);
        if(request.getTaxRate().signum()<0||request.getTaxRate().compareTo(new BigDecimal("100"))>0)throw validation("税率应在0到100之间");
        if(request.getItems()==null||request.getItems().isEmpty())throw validation("请填写发货明细");
        references.lockGoodsQuantityBasis(request.getItems().stream().map(line->line.getGoodsId()).toList());
        int sequence=0;
        for(var line:request.getItems()) {
            if(line.getOrderItemId()!=null)throw validation("客户零星发货不能混用订货单预留；订货发货请使用订单来源流程");
            if(line.getQty()==null||line.getQty().signum()<=0)throw validation("发货数量必须大于零");
            var unit=references.resolveVisibleActiveGoodsUnit(line.getGoodsId(),line.getUnitId(),line.getUnitRate(),++sequence);
            line.setUnitId(unit.unitId());line.setUnitRate(unit.unitRate());
            if(line.getQty().multiply(unit.unitRate()).setScale(4,RoundingMode.HALF_UP).signum()<=0)throw validation("换算后的基本单位数量过小");
            if(free) {line.setPrice(BigDecimal.ZERO);line.setDiscount(BigDecimal.ONE);line.setAmountOriginal(BigDecimal.ZERO);}
            else {
                if(line.getPrice()==null||line.getPrice().signum()<=0)throw validation("收费发货请填写实际单价");
                BigDecimal discount=line.getDiscount()==null?BigDecimal.ONE:line.getDiscount();
                if(discount.signum()<=0||discount.compareTo(BigDecimal.ONE)>0)throw validation("折扣倍率须大于0且不超过1");
                // Pending the platform actual-document precision contract, never silently
                // discard customer money to fit the existing NUMERIC(18,4) storage.
                line.setPrice(exactStoredMoney(line.getPrice()));line.setDiscount(exactStoredMoney(discount));
                line.setAmountOriginal(exactStoredMoney(line.getQty().multiply(line.getPrice()).multiply(discount)));
                if(line.getAmountOriginal().signum()<=0)throw validation("收费金额过小，请核对实际单价或选择不收费");
            }
            line.setAmountLocal(null);line.setCostAmount(null);
        }
    }

    public void validateStored(SalesShipment shipment,List<SalesShipmentItem> items) {
        if(!CustomerShipmentPolicy.direct(shipment))return;
        if(shipment.getClientId()==null||shipment.getSourceOrderId()!=null||items.isEmpty())throw validation("客户零星发货来源不完整");
        boolean free=CustomerShipmentPolicy.free(shipment);
        for(var item:items) {
            if(item.getOrderItemId()!=null||item.getQty()==null||item.getQty().signum()<=0||item.getUnitRate()==null||item.getUnitRate().signum()<=0)
                throw validation("客户发货明细身份或单位不完整");
            if(item.getPrice()==null||item.getAmountOriginal()==null||(free&&(item.getPrice().signum()!=0||item.getAmountOriginal().signum()!=0)))
                throw validation("收费选择与发货金额不一致");
            BigDecimal discount=item.getDiscount()==null?BigDecimal.ONE:item.getDiscount();
            if(item.getQty().multiply(item.getPrice()).multiply(discount).compareTo(item.getAmountOriginal())!=0)
                throw validation("发货数量、单价与金额不一致");
        }
    }
    static BigDecimal exactStoredMoney(BigDecimal amount) {
        try { return amount.setScale(4,RoundingMode.UNNECESSARY); }
        catch (ArithmeticException precisionLoss) { throw validation("当前单据金额无法无损保存，请联系财务核对实际单据金额与汇率；系统未自动四舍五入，本次未生效"); }
    }
    private static ApiException validation(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
