package com.uten.imp.features.master.lifecycle;

import com.uten.imp.features.master.lifecycle.dto.MasterBatchRequests;
import com.uten.imp.features.master.lifecycle.dto.MasterBatchResult;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

/**
 * 主档批量启停 / 批量删除(ADR-111)：一次请求、一个事务、逐条结果 {id, label, ok, reason}。
 *
 * - POST /api/master/{goods|colors|units|warehouses|clients|suppliers|moulds}/batch-status
 *   body {status, items:[{id, version?}]}  → 各主档的 X:status 权限
 * - POST /api/master/{…}/batch-delete
 *   body {items:[{id, version?}]}          → 各主档的 X:delete 权限，逐条引用保护
 * - DELETE /api/master/{…}/{id}            → 单条删除(同一条写路径)；被引用时 409 + 中文原因
 *
 * 每个主档一个显式映射(权限点写死在注解上、可审计)，不用路径变量拼权限。
 */
@RestController
@RequestMapping("/api/master")
@RequiredArgsConstructor
public class MasterLifecycleController {

    private final MasterLifecycleService service;

    @PostMapping("/goods/batch-status")
    @PreAuthorize("hasAuthority('goods:status')")
    public MasterBatchResult goodsStatus(@Valid @RequestBody MasterBatchRequests.StatusRequest body) {
        return service.batchStatus(MasterEntityKind.GOODS, body.status(), body.items());
    }

    @PostMapping("/goods/batch-delete")
    @PreAuthorize("hasAuthority('goods:delete')")
    public MasterBatchResult goodsDelete(@Valid @RequestBody MasterBatchRequests.DeleteRequest body) {
        return service.batchDelete(MasterEntityKind.GOODS, body.items());
    }

    @PostMapping("/colors/batch-status")
    @PreAuthorize("hasAuthority('color:status')")
    public MasterBatchResult colorStatus(@Valid @RequestBody MasterBatchRequests.StatusRequest body) {
        return service.batchStatus(MasterEntityKind.COLOR, body.status(), body.items());
    }

    @PostMapping("/colors/batch-delete")
    @PreAuthorize("hasAuthority('color:delete')")
    public MasterBatchResult colorDelete(@Valid @RequestBody MasterBatchRequests.DeleteRequest body) {
        return service.batchDelete(MasterEntityKind.COLOR, body.items());
    }

    @PostMapping("/units/batch-status")
    @PreAuthorize("hasAuthority('unit:status')")
    public MasterBatchResult unitStatus(@Valid @RequestBody MasterBatchRequests.StatusRequest body) {
        return service.batchStatus(MasterEntityKind.UNIT, body.status(), body.items());
    }

    @PostMapping("/units/batch-delete")
    @PreAuthorize("hasAuthority('unit:delete')")
    public MasterBatchResult unitDelete(@Valid @RequestBody MasterBatchRequests.DeleteRequest body) {
        return service.batchDelete(MasterEntityKind.UNIT, body.items());
    }

    @PostMapping("/warehouses/batch-status")
    @PreAuthorize("hasAuthority('warehouse:status')")
    public MasterBatchResult warehouseStatus(@Valid @RequestBody MasterBatchRequests.StatusRequest body) {
        return service.batchStatus(MasterEntityKind.WAREHOUSE, body.status(), body.items());
    }

    @PostMapping("/warehouses/batch-delete")
    @PreAuthorize("hasAuthority('warehouse:delete')")
    public MasterBatchResult warehouseDelete(@Valid @RequestBody MasterBatchRequests.DeleteRequest body) {
        return service.batchDelete(MasterEntityKind.WAREHOUSE, body.items());
    }

    @PostMapping("/clients/batch-status")
    @PreAuthorize("hasAuthority('client:status')")
    public MasterBatchResult clientStatus(@Valid @RequestBody MasterBatchRequests.StatusRequest body) {
        return service.batchStatus(MasterEntityKind.CLIENT, body.status(), body.items());
    }

    @PostMapping("/clients/batch-delete")
    @PreAuthorize("hasAuthority('client:delete')")
    public MasterBatchResult clientDelete(@Valid @RequestBody MasterBatchRequests.DeleteRequest body) {
        return service.batchDelete(MasterEntityKind.CLIENT, body.items());
    }

    @PostMapping("/suppliers/batch-status")
    @PreAuthorize("hasAuthority('supplier:status')")
    public MasterBatchResult supplierStatus(@Valid @RequestBody MasterBatchRequests.StatusRequest body) {
        return service.batchStatus(MasterEntityKind.SUPPLIER, body.status(), body.items());
    }

    @PostMapping("/suppliers/batch-delete")
    @PreAuthorize("hasAuthority('supplier:delete')")
    public MasterBatchResult supplierDelete(@Valid @RequestBody MasterBatchRequests.DeleteRequest body) {
        return service.batchDelete(MasterEntityKind.SUPPLIER, body.items());
    }

    @PostMapping("/moulds/batch-status")
    @PreAuthorize("hasAuthority('mould:status')")
    public MasterBatchResult mouldStatus(@Valid @RequestBody MasterBatchRequests.StatusRequest body) {
        return service.batchStatus(MasterEntityKind.MOULD, body.status(), body.items());
    }

    @PostMapping("/moulds/batch-delete")
    @PreAuthorize("hasAuthority('mould:delete')")
    public MasterBatchResult mouldDelete(@Valid @RequestBody MasterBatchRequests.DeleteRequest body) {
        return service.batchDelete(MasterEntityKind.MOULD, body.items());
    }

    // ---- 单条删除 ----

    @DeleteMapping("/goods/{id}")
    @PreAuthorize("hasAuthority('goods:delete')")
    public void deleteGoods(@PathVariable UUID id) {
        service.delete(MasterEntityKind.GOODS, id);
    }

    @DeleteMapping("/colors/{id}")
    @PreAuthorize("hasAuthority('color:delete')")
    public void deleteColor(@PathVariable UUID id) {
        service.delete(MasterEntityKind.COLOR, id);
    }

    @DeleteMapping("/units/{id}")
    @PreAuthorize("hasAuthority('unit:delete')")
    public void deleteUnit(@PathVariable UUID id) {
        service.delete(MasterEntityKind.UNIT, id);
    }

    @DeleteMapping("/warehouses/{id}")
    @PreAuthorize("hasAuthority('warehouse:delete')")
    public void deleteWarehouse(@PathVariable UUID id) {
        service.delete(MasterEntityKind.WAREHOUSE, id);
    }

    @DeleteMapping("/clients/{id}")
    @PreAuthorize("hasAuthority('client:delete')")
    public void deleteClient(@PathVariable UUID id) {
        service.delete(MasterEntityKind.CLIENT, id);
    }

    @DeleteMapping("/suppliers/{id}")
    @PreAuthorize("hasAuthority('supplier:delete')")
    public void deleteSupplier(@PathVariable UUID id) {
        service.delete(MasterEntityKind.SUPPLIER, id);
    }

    @DeleteMapping("/moulds/{id}")
    @PreAuthorize("hasAuthority('mould:delete')")
    public void deleteMould(@PathVariable UUID id) {
        service.delete(MasterEntityKind.MOULD, id);
    }
}
