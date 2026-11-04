package com.uten.imp.common.validation;

import com.uten.imp.features.warehouse.inbound.*;
import com.uten.imp.features.warehouse.inbound.dto.*;
import com.uten.imp.features.production.analysis.*;
import com.uten.imp.features.production.fulfillment.ProductionMaterialIncrementContracts;
import com.uten.imp.features.production.quality.ProductionFqcContracts;
import com.uten.imp.features.production.dailyreport.dto.DailyReportMaterialUsageLine;
import com.uten.imp.features.sales.order.dto.OrderYieldRequest;
import com.uten.imp.features.sales.shipment.dto.BatchShipRequest;
import com.uten.imp.features.sales.shipment.dto.ShipmentItemLine;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemLine;
import com.uten.imp.features.sales.ret.dto.ReturnQualityDispositionRequest;
import com.uten.imp.features.sales.ret.dto.ReturnQualityCorrectionRequest;
import com.uten.imp.features.stock.dto.StockBalanceAdjustmentRequest;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.count.StockCountDtos;
import com.uten.imp.features.stock.weight.dto.WeightSampleRequest;
import com.uten.imp.features.purchase.request.PurchaseRequestController;
import com.uten.imp.features.purchase.request.dto.RequestItemLine;
import com.uten.imp.features.purchase.order.dto.OrderItemLine;
import com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine;
import com.uten.imp.features.purchase.ret.dto.ReturnItemLine;
import com.uten.imp.features.master.goods.dto.GoodsSaveRequest;
import com.uten.imp.features.finance.cost.FinanceCostInputContracts;
import com.uten.imp.features.finance.payables.ProcurementIqcRejectionContracts;
import jakarta.validation.Validation;
import jakarta.validation.Validator;
import java.math.BigDecimal;
import java.util.*;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class DocumentQuantityContractTest {
    @Test void publicQuantityBoundariesUseTheSameEffectiveFortyIntegerTwentyFourFractionContract(){
        var covered=new HashSet<String>();
        try(var factory=Validation.buildDefaultValidatorFactory()){
            var validator=factory.getValidator();
            for(var type:List.of(InspectionDispositionRequest.class,BatchInspectionPassRequest.class,BatchInspectionDecideRequest.class,
                    ProcurementArrivalContracts.class,ProcurementIqcStockInContracts.class,ProductionFqcContracts.class,
                    ReturnQualityDispositionRequest.class,ReturnQualityCorrectionRequest.class,MaterialAnalysisContracts.class,
                    AggregateMaterialOrderContracts.class,PreplanFutureSupplyTransfer.class,PreplanMakePublicSupplyService.class,
                    ProductionMaterialIncrementContracts.class,DailyReportMaterialUsageLine.class,StockBalanceAdjustmentRequest.class,
                    StockDocItemLine.class,StockCountDtos.class,WeightSampleRequest.class,RequestItemLine.class,OrderItemLine.class,
                    ReceiptItemLine.class,ReturnItemLine.class,PurchaseRequestController.class,OrderYieldRequest.class,
                    GoodsSaveRequest.class,FinanceCostInputContracts.class,ProcurementIqcRejectionContracts.class,
                    BatchShipRequest.class,ShipmentItemLine.class,MaterialIssueItemLine.class,
                    com.uten.imp.features.sales.ret.dto.ReturnItemLine.class,
                    com.uten.imp.features.subcontract.material_return.dto.MaterialReturnItemLine.class,
                    com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine.class,
                    com.uten.imp.features.subcontract.ret.dto.ReturnItemLine.class))verify(type,validator,covered);
        }
        assertThat(covered).contains("InspectionDispositionRequest.baseQty","Item.expectedRemainingBaseQty","ConfirmItem.baseQty",
                "ArrivalLine.giftQty","DecisionRequest.passQty","ReceiptItemLine.giftQty","GoodsSaveRequest.minOrderQty");
    }
    private static <T> void verify(Class<T> type,Validator validator,Set<String> covered){
        for(var property:validator.getConstraintsForClass(type).getConstrainedProperties()){
            boolean quantity=property.getConstraintDescriptors().stream().anyMatch(c->c.getAnnotation().annotationType()==DocumentQuantity.class);
            if(!quantity)continue;
            String field=property.getPropertyName(),label=type.getSimpleName()+"."+field;covered.add(label);
            assertThat(field.toLowerCase(Locale.ROOT)).as("quantity classification "+label).contains("qty");
            for(String valid:List.of("1e-24","9".repeat(40)+"."+"9".repeat(24),"1."+"0".repeat(80)))
                assertThat(validator.validateValue(type,field,new BigDecimal(valid))).as(label+" valid native quantity").isEmpty();
            assertThat(validator.validateValue(type,field,new BigDecimal("1e-25"))).as(label+" nonzero 25th place").isNotEmpty();
            assertThat(validator.validateValue(type,field,new BigDecimal("1e40"))).as(label+" 41st integer place").isNotEmpty();
        }
        for(Class<?> nested:type.getDeclaredClasses())verify(nested,validator,covered);
    }
    @Test void formatValidationDoesNotChangeEachCallersNullZeroAndSignRules(){
        try(var factory=Validation.buildDefaultValidatorFactory()){
            var validator=factory.getValidator();
            assertThat(validator.validateValue(InspectionDispositionRequest.class,"baseQty",null)).isEmpty();
            assertThat(validator.validateValue(InspectionDispositionRequest.class,"baseQty",BigDecimal.ZERO)).isNotEmpty();
            assertThat(validator.validateValue(ReceiptItemLine.class,"giftQty",null)).isEmpty();
            assertThat(validator.validateValue(ReceiptItemLine.class,"giftQty",BigDecimal.ZERO)).isEmpty();
            assertThat(validator.validateValue(ReceiptItemLine.class,"giftQty",BigDecimal.ONE.negate())).isNotEmpty();
            assertThat(validator.validateValue(StockBalanceAdjustmentRequest.class,"expectedQty",BigDecimal.ONE.negate())).isEmpty();
            assertThat(validator.validateValue(StockBalanceAdjustmentRequest.class,"targetQty",BigDecimal.ONE.negate())).isNotEmpty();
            assertThat(validator.validateValue(com.uten.imp.features.sales.ret.dto.ReturnItemLine.class,"qty",null)).isNotEmpty();
            assertThat(validator.validateValue(com.uten.imp.features.sales.ret.dto.ReturnItemLine.class,"qty",BigDecimal.ZERO)).isEmpty();
        }
    }
}
