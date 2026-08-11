package com.uten.imp.features.org.department.myview;

import com.uten.imp.features.org.department.dto.DepartmentNode;
import com.uten.imp.features.org.department.myview.dto.MyDepartmentRosterDto;
import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.UUID;

/**
 * "我的部门"工作台卡片（问题 #20）——任意已登录员工可用，无需 department:view/employee:view
 * （这两个权限点只授给人事/管理层，普通员工没有）。授权边界收在"只能看自己所在大部门分支"，
 * 校验在 {@link MyDepartmentService} 内完成。
 */
@RestController
@RequestMapping("/api/my-department")
@RequiredArgsConstructor
public class MyDepartmentController {

    private final MyDepartmentService service;

    @GetMapping("/tree")
    public List<DepartmentNode> tree() {
        return service.myBranchTree();
    }

    @GetMapping("/roster")
    public MyDepartmentRosterDto roster(@RequestParam UUID departmentId) {
        return service.roster(departmentId);
    }
}
