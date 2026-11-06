package com.uten.imp.features.master.reference;

import com.uten.imp.audit.AuditRequestContext;
import com.uten.imp.common.readsnapshot.*;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.master.client.ClientService;
import com.uten.imp.features.master.supplier.SupplierService;
import com.uten.imp.features.master.goods.GoodsService;
import com.uten.imp.features.master.goods.dto.GoodsSearchRequest;
import jakarta.servlet.http.*;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.Map;

/** Exactly the existing business capabilities and narrow reference projections, with bounded complete-read proofs. */
@RestController
@RequestMapping("/api/business-references")
@PreAuthorize("isAuthenticated() and !principal.visitor")
public class BusinessMasterSummaryController {
    public record PartyQuery(@NotNull @Valid BusinessMasterReferenceController.PartySearch filter, Integer page, Integer size) { }
    private final BusinessMasterReferenceAccess access;
    private final ClientService clients;
    private final SupplierService suppliers;
    private final GoodsService goods;
    private final MasterSummaryReadSupport summaries;
    public BusinessMasterSummaryController(BusinessMasterReferenceAccess access, ClientService clients,
            SupplierService suppliers, GoodsService goods, MasterSummaryReadSupport summaries) {
        this.access=access;this.clients=clients;this.suppliers=suppliers;this.goods=goods;this.summaries=summaries;
    }
    @PostMapping("/clients/summaries")
    public VersionedSummaryPages.Snapshot<MasterSummaryReadSupport.Payload<PartyReference>> clients(
            @Valid @RequestBody PartyQuery body, @RequestParam(required=false) String readSnapshotRevision,
            HttpServletRequest request, HttpServletResponse response) {
        access.require("client");AuditRequestContext.markControlledRead(request);
        var query=new MasterSummaryReadSupport.Query<>(body.filter(),body.page(),body.size(),null,null);
        var value=summaries.readAuthorized("client-master-list","client","business-reference-client",query,readSnapshotRevision,
                ()->access.require("client"),(filter,page,size,sort,order)->clients.referencePage(filter.categoryId(),filter.keyword(),
                        !Boolean.FALSE.equals(filter.selectableOnly()),!Boolean.FALSE.equals(filter.excludeLegacyFinanceStub()),page,size));
        response.setHeader("X-Uten-Read-Scope-Version",value.readScopeVersion());return value;
    }
    @PostMapping("/suppliers/summaries")
    public VersionedSummaryPages.Snapshot<MasterSummaryReadSupport.Payload<PartyReference>> suppliers(
            @Valid @RequestBody PartyQuery body, @RequestParam(required=false) String readSnapshotRevision,
            HttpServletRequest request, HttpServletResponse response) {
        access.require("supplier");AuditRequestContext.markControlledRead(request);
        var query=new MasterSummaryReadSupport.Query<>(body.filter(),body.page(),body.size(),null,null);
        var value=summaries.readAuthorized("supplier-master-list","supplier","business-reference-supplier",query,readSnapshotRevision,
                ()->access.require("supplier"),(filter,page,size,sort,order)->suppliers.referencePage(filter.categoryId(),filter.keyword(),
                        !Boolean.FALSE.equals(filter.selectableOnly()),page,size));
        response.setHeader("X-Uten-Read-Scope-Version",value.readScopeVersion());return value;
    }
    @PostMapping("/goods/summaries")
    public VersionedSummaryPages.Snapshot<MasterSummaryReadSupport.Payload<Map<String,Object>>> goods(
            @Valid @RequestBody GoodsSearchRequest body, @RequestParam(required=false) String readSnapshotRevision,
            HttpServletRequest request, HttpServletResponse response) {
        access.require("goods");AuditRequestContext.markControlledRead(request);
        GoodsReferenceProjection.validateQuery(body.filter(),body.sort());
        var query=new MasterSummaryReadSupport.Query<>(body.filter(),body.requestedPage(),body.requestedSize(),body.sort(),body.order());
        var value=summaries.readAuthorized("goods-master-list","master_goods","business-reference-goods",query,readSnapshotRevision,
                ()->access.require("goods"),(filter,page,size,sort,order)->{
                    var result=goods.list(filter,page,size,sort,order);
                    boolean includeMasterStock=access.canReadMasterGoods();
                    return new PageResponse<>(result.getItems().stream().map(item->GoodsReferenceProjection.of(item,includeMasterStock)).toList(),
                            result.getPage(),result.getSize(),result.getTotal(),result.getTotalPages());
                });
        response.setHeader("X-Uten-Read-Scope-Version",value.readScopeVersion());return value;
    }
}
