package com.uten.imp.security;

import org.springframework.stereotype.Component;

import java.util.Set;

/**
 * 数据可见性策略（最小权限）。由 DTO 映射层调用，决定某角色能否看到敏感明文。
 * <ul>
 *   <li>身份证号 / 手机号 / 银行卡号 / 开户行：仅 hr + admin</li>
 *   <li>薪资额（基本/绩效/社保/公积金/补贴）：hr + finance + admin</li>
 *   <li>manager 与普通员工：永不触碰</li>
 * </ul>
 */
@Component
public class DataAccessPolicy {

    public boolean canSeeIdCardAndBank(Set<String> roles) {
        return roles.contains("hr") || roles.contains("admin");
    }

    public boolean canSeeSalary(Set<String> roles) {
        return roles.contains("hr") || roles.contains("finance") || roles.contains("admin");
    }

    public boolean isAdmin(Set<String> roles) {
        return roles.contains("admin");
    }
}
