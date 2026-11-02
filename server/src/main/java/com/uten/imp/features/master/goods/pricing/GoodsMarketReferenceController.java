package com.uten.imp.features.master.goods.pricing;

import com.uten.imp.audit.AuditDetailViewRecorder;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import com.uten.imp.security.PriceAnalysisAccessPolicy;
import org.springframework.web.bind.annotation.*;
import java.util.List;
import java.util.UUID;
import static com.uten.imp.features.master.goods.pricing.MaterialForecastContracts.*;

@RestController
@RequiredArgsConstructor
@RequestMapping("/api/master/goods/{goodsId}/price-analysis/market")
@PreAuthorize(PriceAnalysisAccessPolicy.PURCHASE_READ)
public class GoodsMarketReferenceController {
    private final GoodsMarketReferenceService service;
    private final AuditDetailViewRecorder audit;
    @GetMapping
    public Envelope get(@PathVariable UUID goodsId) {
        Envelope result=service.get(goodsId);
        audit.record("view_goods_price_analysis","goods",goodsId,null,null,"货品市场参考");
        return result;
    }
    @GetMapping("/catalog")
    public List<Benchmark> catalog(@PathVariable UUID goodsId){return service.catalog(goodsId);}
    @PutMapping
    @PreAuthorize(PriceAnalysisAccessPolicy.PURCHASE_WRITE)
    public Envelope put(@PathVariable UUID goodsId,@RequestBody BindingRequest request){return service.put(goodsId,request);}
}
