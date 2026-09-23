package com.uten.imp.features.visitor;

import com.uten.imp.features.visitor.dto.VisitorScanDto.EmployeeDirectoryItem;
import jakarta.servlet.http.HttpServletRequest;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * 访客选择接待人(security-08 / permissions-13)：只对访客主体开放，
 * 只能「先搜再选」——姓名关键字至少 2 个字、最多返回 5 人、只含可对外接待的员工，
 * 不提供部门树或按部门列举，按账号与来源地址限流并逐次审计，
 * 不让自助注册的外部账号翻出全公司名册。
 */
@RestController
@RequestMapping("/api/visitor/directory")
@RequiredArgsConstructor
@PreAuthorize("principal.visitor and hasAuthority('" + VisitorAuthorities.APPLY + "')")
public class VisitorDirectoryController {

    private final VisitorDirectoryService service;

    @GetMapping("/employees")
    public List<EmployeeDirectoryItem> employees(@RequestParam(required = false) String keyword,
                                                 HttpServletRequest http) {
        return service.searchHosts(keyword, http.getRemoteAddr());
    }
}
