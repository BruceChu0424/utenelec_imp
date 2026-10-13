package com.uten.imp.features.master.goods.pricing;

import com.uten.imp.audit.AuditDetailViewRecorder;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.time.LocalDate;
import java.util.UUID;
import static com.uten.imp.features.master.goods.pricing.GoodsPriceContracts.*;

@RestController
@RequiredArgsConstructor
@RequestMapping("/api/master/goods")
@PreAuthorize("hasAuthority('goods:view') and hasAuthority('goods:price_analysis:view')")
public class GoodsPriceAnalysisController {
    private final GoodsPriceAnalysisService prices;
    private final AuditDetailViewRecorder audit;
    @GetMapping("/{goodsId}/price-analysis")
    public Analysis analysis(@PathVariable UUID goodsId,@RequestParam Kind kind,@RequestParam(required=false) Integer days,
            @RequestParam(required=false) UUID supplierId,@RequestParam(required=false) UUID clientId,
            @RequestParam(required=false) UUID colorId,@RequestParam(required=false) UUID unitId,
            @RequestParam(required=false) UUID currencyId,@RequestParam(required=false) String taxRate,
            @RequestParam(required=false) String quantity,@RequestParam(required=false) String unitRate,
            @RequestParam(required=false) UUID excludeOrderId,@RequestParam(required=false) UUID confirmedCostSnapshotId,
            @RequestParam(required=false) String targetMarginRate) {
        Analysis result=prices.analysis(new Query(goodsId,kind,days,supplierId,colorId,unitId,currencyId,taxRate,quantity,excludeOrderId,clientId,confirmedCostSnapshotId,targetMarginRate,unitRate));
        audit.record("view_goods_price_analysis","goods",goodsId,result.goodsCode(),null,"货品价格分析");
        return result;
    }
    @PostMapping("/price-analysis/check")
    public CheckResult check(@RequestBody CheckRequest request){return prices.check(request);}
    @GetMapping("/{goodsId}/price-analysis/detail")
    public Detail detail(@PathVariable UUID goodsId,@RequestParam Kind kind,@RequestParam String sourceType,
            @RequestParam UUID sourceId,@RequestParam UUID sourceItemId,@RequestParam(required=false) UUID historyVersionId,
            @RequestParam String expectedSourceRevision) {
        Detail result=prices.detail(goodsId,new DetailQuery(kind,sourceType,sourceId,sourceItemId,historyVersionId,expectedSourceRevision));
        audit.record("view_goods_price_detail","goods",goodsId,result.observation().goodsCodeSnapshot(),null,"货品价格详情");
        return result;
    }
    @GetMapping("/{goodsId}/price-analysis/history")
    public History history(@PathVariable UUID goodsId,@RequestParam Kind kind,@RequestParam(required=false) UUID supplierId,
            @RequestParam(required=false) UUID clientId,@RequestParam(required=false) UUID colorId,@RequestParam(required=false) UUID unitId,
            @RequestParam(required=false) UUID currencyId,@RequestParam(required=false) String taxRate,@RequestParam(required=false) String unitRate,
            @RequestParam(required=false) LocalDate from,@RequestParam(required=false) LocalDate to,
            @RequestParam(required=false) String cursor,@RequestParam(required=false) Integer pageSize) {
        var result=prices.history(new HistoryQuery(new Query(goodsId,kind,null,supplierId,colorId,unitId,currencyId,taxRate,null,null,clientId,null,null,unitRate),from,to,cursor,pageSize));
        audit.record("view_goods_price_analysis_history","goods",goodsId,null,null,"货品价格历史");return result;
    }
}
