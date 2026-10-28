package com.uten.imp.features.archive;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.ServerOperationsReadAccess;
import lombok.RequiredArgsConstructor;
import org.springframework.dao.EmptyResultDataAccessException;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;
import java.util.UUID;

/**
 * 归档资格与快照包只读入口（B3 试点）。
 *
 * <p>试点阶段挂在服务器运维读权限下（比业务权限更收紧）：归档包是治理对象，
 * 面向业务岗位的历史读取入口在归档分层正式推广（R5.06）时按对象权限另行开放。
 * 读取本身只返回登记事实与快照字节，绝不触发搬移或删除。
 */
@RestController
@RequestMapping("/api/admin/archive")
@RequiredArgsConstructor
@PreAuthorize(ServerOperationsReadAccess.EXPRESSION)
public class BusinessArchiveController {

    private final BusinessArchiveEligibilityService eligibility;

    @GetMapping("/eligibility")
    public ResponseEntity<Map<String, Object>> eligibility(
            @RequestParam(defaultValue = "PURCHASE_ORDER") String family,
            @RequestParam(required = false) Boolean eligible,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return ResponseEntity.ok().cacheControl(CacheControl.noStore())
                .body(eligibility.eligibilityPage(family, eligible, page, size));
    }

    @GetMapping("/packages/{family}/{objectId}")
    public ResponseEntity<Map<String, Object>> latestPackage(
            @PathVariable String family,
            @PathVariable UUID objectId) {
        try {
            return ResponseEntity.ok().cacheControl(CacheControl.noStore())
                    .body(eligibility.latestPackage(family, objectId));
        } catch (EmptyResultDataAccessException none) {
            throw new ApiException(ErrorCode.NOT_FOUND, "该对象还没有已验证的归档包");
        }
    }
}
