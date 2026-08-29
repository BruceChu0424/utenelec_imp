package com.uten.imp.features.org.employee;

import com.uten.imp.features.org.employee.dto.EmployeeDetail;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 员工自助资料读取入口。
 *
 * <p>对象范围由 {@link EmployeeQueryService#myDetail()} 从当前 {@code AuthUser.employeeId}
 * 固定解析；接口不接受 employeeId，避免调用方切换对象读取他人档案。
 */
@RestController
@RequestMapping("/api/profile/me")
@RequiredArgsConstructor
public class MyProfileController {

    private final EmployeeQueryService queryService;

    @GetMapping
    @PreAuthorize("hasAuthority('profile:edit:self')")
    public EmployeeDetail me() {
        return queryService.myDetail();
    }
}
