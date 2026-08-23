package com.uten.imp.features.master.paymentstyle;

import com.uten.imp.features.master.paymentstyle.dto.PaymentStyleDetail;
import com.uten.imp.features.master.paymentstyle.dto.PaymentStyleNode;
import com.uten.imp.features.master.paymentstyle.dto.PaymentStyleSaveRequest;
import com.uten.imp.features.master.paymentstyle.dto.PaymentStyleUpdateRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
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

import java.util.List;
import java.util.UUID;

/**
 * 收付款类别 API（基础资料-收付款类别）。
 *
 * - GET    /api/master/payment-styles/tree?category=          → 全树 / 按大类过滤
 * - GET    /api/master/payment-styles/{id}/subtree            → 子树
 * - GET    /api/master/payment-styles/{id}                    → 详情
 * - POST   /api/master/payment-styles                         → 新建（payment_style:edit）
 * - PUT    /api/master/payment-styles/{id}                    → 编辑（payment_style:edit）
 * - DELETE /api/master/payment-styles/{id}                    → 保留兼容端点，财务类别不允许删除（请停用）
 *
 * 读写分离：查询要求 payment_style:view，维护要求 payment_style:edit；
 * 具体授权范围以当前权限种子和部门继承配置为准。
 */
@RestController
@RequestMapping("/api/master/payment-styles")
@RequiredArgsConstructor
public class PaymentStyleController {

    private final PaymentStyleService service;

    @GetMapping("/tree")
    @PreAuthorize("hasAuthority('payment_style:view')")
    public List<PaymentStyleNode> tree(@RequestParam(required = false) String category) {
        return service.treeByCategory(category);
    }

    @GetMapping("/{id}/subtree")
    @PreAuthorize("hasAuthority('payment_style:view')")
    public List<PaymentStyleNode> subtree(@PathVariable UUID id) {
        return service.subtree(id);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('payment_style:view')")
    public PaymentStyleDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('payment_style:create')")
    public PaymentStyleDetail create(@Valid @RequestBody PaymentStyleSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAnyAuthority('payment_style:edit', 'payment_style:status', 'payment_style:move', 'payment_style:reorder')")
    public PaymentStyleDetail update(@PathVariable UUID id, @Valid @RequestBody PaymentStyleUpdateRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('payment_style:edit')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }
}
