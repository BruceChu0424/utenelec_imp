package com.uten.imp.features.sales.order;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.features.sales.order.dto.OrderDetail;
import com.uten.imp.features.sales.order.dto.OrderListItem;
import com.uten.imp.features.sales.order.dto.OrderQueryFilter;
import com.uten.imp.features.sales.order.dto.OrderSaveRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * 销售订货单 API（销售管理）。CRUD + 审核 + 红冲（订货不入库、不立应收）+ 中止位切换。
 */
@RestController
@RequestMapping("/api/sales/orders")
@RequiredArgsConstructor
public class SalesOrderController {

    private final SalesOrderService service;
    private final SalesOrderTimelineService timelineService;
    private final AuditDetailViewRecorder viewAudit;

    @GetMapping
    @PreAuthorize("hasAuthority('sales_order:view')")
    public PageResponse<OrderListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID clientId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) Boolean closed,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) java.util.List<Short> chain,
            @RequestParam(required = false) UUID sellerId,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.list(new OrderQueryFilter(keyword, clientId, status, closed, dateFrom, dateTo, chain, sellerId), page, size, sort, order);
    }

    /** 工作台统计卡：待生产 / 生产中 / 待发货 / 本月完成（同列表数据范围）。 */
    @GetMapping("/stats")
    @PreAuthorize("hasAuthority('sales_order:view')")
    public com.uten.imp.features.sales.order.dto.OrderStats stats() {
        return service.stats();
    }

    /** 订单进度看板（订单进度查询卡）：已审订单生产/发货进度聚合 + 派生阶段；stage 筛选（OPEN=待完成）。 */
    @GetMapping("/progress")
    @PreAuthorize("hasAuthority('sales_order:view')")
    public PageResponse<com.uten.imp.features.sales.order.dto.OrderProgressRow> progress(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(defaultValue = "") String stage) {
        return service.progress(page, size, stage);
    }

    /** 订单进度各阶段计数：顶部筛选卡（待完成/待排产/生产中/可发货/已发货）的全量口径。 */
    @GetMapping("/progress/stage-counts")
    @PreAuthorize("hasAuthority('sales_order:view')")
    public java.util.Map<String, Long> progressStageCounts() {
        return service.progressStageCounts();
    }

    /** 批量发货可发行（SOP §一9）：reserved_qty>0 的订单行，归属隔离与列表同口径。 */
    @GetMapping("/shippable-lines")
    @PreAuthorize("hasAuthority('sales_order:view')")
    public List<com.uten.imp.features.sales.order.dto.OrderShippableLine> shippableLines() {
        return service.shippableLines();
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('sales_order:view')")
    public OrderDetail detail(@PathVariable UUID id) {
        OrderDetail detail = service.detail(id);
        viewAudit.record(
                "view_sales_order_detail", "sales_orders", id,
                detail.getBillNo(), detail.getLegacyId(), "销售订货单");
        return detail;
    }

    /** 排产进度（链路另一端）：每行 订货/可发/已排/已产 + 关联生产计划溯源。 */
    @GetMapping("/{id}/plan-progress")
    @PreAuthorize("hasAuthority('sales_order:view')")
    public List<com.uten.imp.features.sales.order.dto.PlanProgressLine> planProgress(
            @PathVariable UUID id) {
        return service.planProgress(id);
    }

    /**
     * 全链路进度时间线（快递式追踪）：下单→销售审核→财务审核→物料分析→物料准备
     * （采购/委外订货+财务审批）→生产计划→生产→发货→结案；每环带责任人与时间，
     * 已发生事件最新在最上，PENDING 占位垫底。归属校验与 detail 同口径。
     */
    @GetMapping("/{id}/progress-timeline")
    @PreAuthorize("hasAuthority('sales_order:view')")
    public List<com.uten.imp.features.sales.order.dto.OrderProgressTimelineEvent> progressTimeline(
            @PathVariable UUID id) {
        return timelineService.timeline(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('sales_order:create')")
    public OrderDetail create(@Valid @RequestBody OrderSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('sales_order:edit')")
    public OrderDetail update(@PathVariable UUID id, @Valid @RequestBody OrderSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('sales_order:delete')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('sales_order:approve')")
    public OrderDetail approve(@PathVariable UUID id) {
        return service.approve(id);
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('sales_order:reverse')")
    public OrderDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }

    /** 中止位切换（独立业务位）。 */
    @PostMapping("/{id}/stopped")
    @PreAuthorize("hasAuthority('sales_order:stop')")
    public OrderDetail setStopped(@PathVariable UUID id, @RequestParam boolean stopped) {
        return service.toggleStopped(id, stopped);
    }

    /** 订单改量：已审订单逐行改数量；涉及已排产行需生产部权限点。 */
    @PostMapping("/{id}/change-qty")
    @PreAuthorize("hasAuthority('sales_order:change_qty')")
    public OrderDetail changeQty(@PathVariable UUID id,
                                 @Valid @RequestBody com.uten.imp.features.sales.order.dto.OrderChangeQtyRequest req) {
        return service.changeQty(id, req);
    }

    /** 订单取消：已审未发货整单取消（释放预留+断排产联动）。 */
    @PostMapping("/{id}/cancel")
    @PreAuthorize("hasAuthority('sales_order:cancel')")
    public OrderDetail cancel(@PathVariable UUID id) {
        return service.cancel(id);
    }

    @PostMapping("/{id}/partial-shipment-confirmation")
    @PreAuthorize("hasAuthority('sales_order:confirm_partial_shipment')")
    public OrderDetail setPartialShipmentConfirmation(
            @PathVariable UUID id,
            @Valid @RequestBody
            com.uten.imp.features.sales.order.dto.PartialShipmentConfirmationRequest req) {
        return service.setPartialShipmentConfirmation(id, req);
    }

    // ======================= 预留生命周期 + 稀缺仲裁 =======================

    /** 设置订单行优先级：1急单/2普通/3现货；急单须填原因。仅稀缺让单决策用，不自动抢占。 */
    @PostMapping("/items/{id}/priority")
    @PreAuthorize("hasAuthority('sales_order:priority')")
    public OrderDetail setLinePriority(@PathVariable UUID id,
                                       @Valid @RequestBody com.uten.imp.features.sales.order.dto.OrderPriorityRequest req) {
        return service.setLinePriority(id, req);
    }

    /**
     * 稀缺让单重排：主管释放某低优先级订单行的现货预留，库存回池供急单占用，
     * 该行缺口自动回调度待排产，并通知其归属销售。复用既有释放原语 + 出货驳回同款状态回退。
     */
    @PostMapping("/items/{id}/yield-reservation")
    @PreAuthorize("hasAuthority('sales_order:reallocate')")
    public OrderDetail yieldReservation(@PathVariable UUID id,
                                        @Valid @RequestBody com.uten.imp.features.sales.order.dto.OrderYieldRequest req) {
        return service.yieldReservation(id, req);
    }

    /** 稀缺库存占用视图：某货品+颜色的全部生效预留 + 订单上下文 + 持有逾期，供让单面板决策。 */
    @GetMapping("/reservations/scarce")
    @PreAuthorize("hasAuthority('sales_order:reallocate')")
    public List<com.uten.imp.features.sales.order.dto.ScarceStockReservationView> scarceReservations(
            @RequestParam UUID goodsId,
            @RequestParam(required = false) UUID colorId) {
        return service.scarceReservations(goodsId, colorId);
    }
}
