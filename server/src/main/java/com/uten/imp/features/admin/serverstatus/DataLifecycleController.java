package com.uten.imp.features.admin.serverstatus;

import com.uten.imp.features.admin.serveroperations.ServerOperationsPermissions;
import lombok.RequiredArgsConstructor;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * 数据生命周期策略清册只读入口（B3）。
 *
 * <p>与服务器状态/存储页同一读权限：管理员可以核对「保存了什么、按什么规则、
 * 由哪个任务维护」；策略本身只能通过前向迁移变更，不在运行时接口修改。
 */
@RestController
@RequestMapping("/api/admin/data-lifecycle")
@RequiredArgsConstructor
@PreAuthorize(ServerOperationsPermissions.READ_EXPRESSION)
public class DataLifecycleController {

    private final DataLifecyclePolicyService service;

    @GetMapping
    public ResponseEntity<List<DataLifecyclePolicyService.PolicyRow>> list(
            @RequestParam(required = false) String retentionContract) {
        List<DataLifecyclePolicyService.PolicyRow> rows = retentionContract == null
                || retentionContract.isBlank()
                ? service.list()
                : service.byContract(retentionContract);
        return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(rows);
    }
}
