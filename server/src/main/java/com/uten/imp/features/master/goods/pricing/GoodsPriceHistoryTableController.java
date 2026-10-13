package com.uten.imp.features.master.goods.pricing;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditDetailViewRecorder;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import org.springframework.format.annotation.DateTimeFormat;
import java.time.LocalDate;
import java.util.Map;
import java.util.UUID;
import static com.uten.imp.features.master.goods.pricing.GoodsPriceContracts.*;
import static com.uten.imp.features.master.goods.pricing.GoodsPriceHistoryTableContracts.*;

@RestController
@RequiredArgsConstructor
@RequestMapping("/api/master/goods/{goodsId}/price-analysis/history/table")
@PreAuthorize("hasAuthority('goods:view') and hasAuthority('goods:price_analysis:view')")
public class GoodsPriceHistoryTableController {
    private final GoodsPriceHistoryTableService history;
    private final ObjectMapper json;
    private final AuditDetailViewRecorder audit;
    @GetMapping
    public TablePage table(@PathVariable UUID goodsId,@RequestParam Kind kind,
            @RequestParam(required=false) UUID supplierId,@RequestParam(required=false) UUID clientId,
            @RequestParam(required=false) UUID colorId,@RequestParam(required=false) UUID unitId,
            @RequestParam(required=false) UUID currencyId,@RequestParam(required=false) String taxRate,@RequestParam(required=false) String unitRate,
            @RequestParam(required=false) @DateTimeFormat(iso=DateTimeFormat.ISO.DATE) LocalDate from,@RequestParam(required=false) @DateTimeFormat(iso=DateTimeFormat.ISO.DATE) LocalDate to,
            @RequestParam(required=false) Integer page,@RequestParam(required=false) Integer size,
            @RequestParam(required=false) String sort,@RequestParam(required=false) Boolean ascending,@RequestParam(required=false) String filters) {
        var result=history.table(query(goodsId,kind,supplierId,clientId,colorId,unitId,currencyId,taxRate,unitRate,from,to,page,size,sort,ascending,filters));
        audit.record("view_goods_price_analysis_history","goods",goodsId,null,null,"货品价格历史");return result;
    }
    @GetMapping("/facets")
    public FacetPage facets(@PathVariable UUID goodsId,@RequestParam Kind kind,@RequestParam String column,
            @RequestParam(required=false) String search,@RequestParam(required=false) Integer page,@RequestParam(required=false) Integer size,
            @RequestParam(required=false) UUID supplierId,@RequestParam(required=false) UUID clientId,
            @RequestParam(required=false) UUID colorId,@RequestParam(required=false) UUID unitId,
            @RequestParam(required=false) UUID currencyId,@RequestParam(required=false) String taxRate,@RequestParam(required=false) String unitRate,
            @RequestParam(required=false) @DateTimeFormat(iso=DateTimeFormat.ISO.DATE) LocalDate from,@RequestParam(required=false) @DateTimeFormat(iso=DateTimeFormat.ISO.DATE) LocalDate to,@RequestParam(required=false) String filters) {
        return history.facets(new FacetQuery(query(goodsId,kind,supplierId,clientId,colorId,unitId,currencyId,taxRate,unitRate,from,to,null,null,null,null,filters),column,search,page,size));
    }
    private TableQuery query(UUID goodsId,Kind kind,UUID supplier,UUID client,UUID color,UUID unit,UUID currency,
            String tax,String rate,LocalDate from,LocalDate to,Integer page,Integer size,String sort,Boolean ascending,String filters) {
        Map<String,String> parsed=Map.of();
        if(filters!=null&&!filters.isBlank()){
            if(filters.length()>8192)throw GoodsPriceAnalysisService.invalid("历史筛选条件过长");
            try{parsed=json.readValue(filters,new TypeReference<>(){});if(parsed==null)throw new IllegalArgumentException();}
            catch(Exception invalid){throw GoodsPriceAnalysisService.invalid("历史筛选格式无效");}
        }
        return new TableQuery(new Query(goodsId,kind,null,supplier,color,unit,currency,tax,null,null,client,null,null,rate),from,to,page,size,sort,ascending,parsed);
    }
}
