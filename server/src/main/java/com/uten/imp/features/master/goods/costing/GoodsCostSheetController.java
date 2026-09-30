package com.uten.imp.features.master.goods.costing;

import com.uten.imp.application.port.GoodsActualCostQueryPort;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;
import static com.uten.imp.features.master.goods.costing.GoodsCostContracts.*;

@RestController
@RequestMapping("/api/master/goods/cost-sheets")
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('goods:cost:view') and hasAuthority('goods:view')")
public class GoodsCostSheetController {
    private final GoodsCostSheetService service;
    private final GoodsActualCostSnapshotService actual;
    @GetMapping public List<SheetSummary> list(@RequestParam UUID goodsId){return service.list(goodsId);}
    @PostMapping public Sheet create(@RequestBody SaveRequest request){return service.create(request);}
    @GetMapping("/{id}") public Sheet get(@PathVariable UUID id){return service.get(id);}
    @PutMapping("/{id}") public Sheet save(@PathVariable UUID id,@RequestBody SaveRequest request){return service.save(id,request);}
    @PostMapping("/preview") public java.util.Map<String,Object> preview(@RequestBody DraftInput input){return service.previewPayload(input);}
    @PostMapping("/convert-currency") public ConvertedCurrency convertCurrency(@RequestBody ConvertCurrencyRequest input){return service.convertCurrency(input);}
    @PostMapping("/{id}/confirm") public Sheet confirm(@PathVariable UUID id,@RequestBody Command request){return service.confirm(id,request);}
    @PostMapping("/{id}/copy") public Sheet copy(@PathVariable UUID id,@RequestBody CopyCommand request){return service.copy(id,request);}
    @GetMapping("/{id}/snapshots") public List<SnapshotSummary> snapshots(@PathVariable UUID id){return service.snapshots(id);}
    @PostMapping("/{id}/snapshots") public Snapshot snapshot(@PathVariable UUID id,@RequestBody Command request){return service.snapshot(id,request);}
    @GetMapping("/snapshots/{id}") public Snapshot readSnapshot(@PathVariable UUID id){return service.readSnapshot(id);}
    @GetMapping("/templates") public List<Template> templates(@RequestParam(required=false) UUID goodsId,@RequestParam(required=false) UUID clientId){return service.templates(goodsId,clientId);}
    @PostMapping("/templates") public Template createTemplate(@RequestBody TemplateSave request){return service.saveTemplate(null,request);}
    @PutMapping("/templates/{id}") public Template saveTemplate(@PathVariable UUID id,@RequestBody TemplateSave request){return service.saveTemplate(id,request);}
    @GetMapping("/actual") public java.util.Map<String,Object> actual(@RequestParam UUID goodsId,
            @RequestParam(required=false) UUID executionSegmentId,@RequestParam(required=false) LocalDate from,
            @RequestParam(required=false) LocalDate to,@RequestParam(required=false) UUID revisionId) {
        service.requireGoodsScope(goodsId);
        return actual.view(new GoodsActualCostQueryPort.Query(goodsId,executionSegmentId,from,to,revisionId));
    }
}
