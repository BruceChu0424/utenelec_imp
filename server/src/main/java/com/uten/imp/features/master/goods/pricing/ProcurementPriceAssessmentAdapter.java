package com.uten.imp.features.master.goods.pricing;

import com.uten.imp.application.port.ProcurementPriceAssessmentPort;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import static com.uten.imp.features.master.goods.pricing.GoodsPriceContracts.*;
import static com.uten.imp.features.master.goods.pricing.GoodsPriceSourceReader.decimalText;

@Component
@RequiredArgsConstructor
public class ProcurementPriceAssessmentAdapter implements ProcurementPriceAssessmentPort {
    private final GoodsPriceAnalysisService prices;
    @Override public boolean available(String kind){try{return prices.available(Kind.valueOf(kind));}catch(IllegalArgumentException|NullPointerException invalid){return false;}}
    @Override @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public Assessment assess(Request request) {
        if(request==null||!available(request.kind()))return Assessment.unavailable();
        if(request.items()==null||request.items().isEmpty())return new Assessment("CHECKED",OffsetDateTime.now(),List.of());
        var rowKeys=new HashSet<String>();
        for(var row:request.items())if(row==null||row.rowKey()==null||row.rowKey().isBlank()||!rowKeys.add(row.rowKey()))
            throw GoodsPriceAnalysisService.invalid("整单价格核对必须包含唯一行标识");
        var items=request.items().stream().map(i->new CheckItem(i.rowKey(),i.goodsId(),i.supplierId(),i.colorId(),i.unitId(),i.currencyId(),decimalText(i.taxRate()),
                decimalText(i.quantity()),decimalText(i.unitPrice()),decimalText(i.totalAmountInput()),i.hasAdditionalCharges()?List.of(Map.<String,Object>of("operation","UNRESOLVED")):List.of(),decimalText(i.unitRate()),decimalText(i.giftQuantity()))).toList();
        List<Warning> warnings=new ArrayList<>();OffsetDateTime checkedAt=null;
        for(int start=0;start<items.size();start+=100){
            CheckResult result=prices.check(new CheckRequest(Kind.valueOf(request.kind()),180,request.excludeOrderId(),List.copyOf(items.subList(start,Math.min(start+100,items.size())))));
            checkedAt=result.checkedAt();
            warnings.addAll(result.rows().stream().map(r->new Warning(r.rowKey(),"INSUFFICIENT".equals(r.severity())?r.status():r.severity(),
                    r.referencePrice(),r.weightedAveragePrice(),r.inputPrice(),r.percentageDeviation(),r.estimatedImpact(),r.sampleCount(),r.confidence(),r.message())).toList());
        }
        return new Assessment("CHECKED",checkedAt,List.copyOf(warnings));
    }
}
