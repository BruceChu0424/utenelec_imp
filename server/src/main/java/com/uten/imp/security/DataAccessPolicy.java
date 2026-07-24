package com.uten.imp.security;

import org.springframework.stereotype.Component;

import java.util.Set;

/**
 * 数据可见性策略（最小权限）。由 DTO 映射层调用，决定能否看到敏感明文。
 *
 * <p>角色体系下线（ADR-011/V29）后改为按【权限点】判定，入参为当前用户的
 * 有效权限集合（JWT permissions claim，登录/刷新时由 PermissionResolver 合成，
 * 超管恒为全量因此天然放行）：
 * <ul>
 *   <li>身份证号 / 手机号 / 银行卡号 / 开户行：employee:pii:view（V30 新增）</li>
 *   <li>薪资额（基本/绩效/社保/公积金/补贴）：employee:compensation:view</li>
 * </ul>
 * 旧实现按角色名（hr/finance/admin）判断：角色已从权限模型下线后，
 * 残留角色会导致"权限被收回但仍能看明文"（fail-open），故废弃。
 */
@Component
public class DataAccessPolicy {

    /** 查看员工证件/手机号/银行卡字段 */
    public static final String PII_VIEW = "employee:pii:view";
    /** 查看员工薪资字段 */
    public static final String COMPENSATION_VIEW = "employee:compensation:view";

    public boolean canSeeIdCardAndBank(Set<String> permissions) {
        return permissions.contains(PII_VIEW);
    }

    public boolean canSeeSalary(Set<String> permissions) {
        return permissions.contains(COMPENSATION_VIEW);
    }
}
