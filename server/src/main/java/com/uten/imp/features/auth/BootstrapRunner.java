package com.uten.imp.features.auth;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.BootstrapProperties;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.auth.model.*;
import com.uten.imp.features.rbac.*;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.core.annotation.Order;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;

/**
 * 首次启动创建引导超管账号。
 * <p>
 * 该账号语义上是"超级管理员"：
 * <ul>
 *   <li>{@code users.is_super_admin = true}（V16 字段）</li>
 *   <li>不设置 position（V08 INSERT 不写）</li>
 *   <li>不依赖 role_permissions 是否齐全——PermissionResolver.permsOf() 在 isSuperAdmin=true 时
 *       直接返回 permissions 表全量</li>
 * </ul>
 * 登录账号取自 {@code uten.bootstrap.admin-login}（默认管理员手机号 17665410007，替代历史的 "admin"）；
 * 密码取自 BOOTSTRAP_ADMIN_PASSWORD，Argon2id 哈希入库，must_change_password=true。
 * 已存在则严格跳过；运行时不会把被人工撤销的超管权限重新授回。V205 迁移把既有 {@code admin} 登录名
 * 改为管理员手机号，使既有库与新默认一致（Flyway 先于本 Runner 执行）。
 * SQL 迁移已种入 admin 员工档案（code=ADMIN）。
 */
@Slf4j
@Order(1)
@Component
@RequiredArgsConstructor
public class BootstrapRunner implements ApplicationRunner {

    private final UserAccountRepository userRepo;
    private final EmployeeRepository employeeRepo;
    private final RoleRepository roleRepo;
    private final UserRoleRepository userRoleRepo;
    private final PasswordEncoder passwordEncoder;
    private final BootstrapProperties props;

    @Override
    public void run(ApplicationArguments args) {
        if (userRepo.existsByLoginAccount(props.getAdminLogin())) {
            log.info("引导超管账号 [{}] 已存在，跳过", props.getAdminLogin());
            return;
        }
        Employee adminEmp = employeeRepo.findByCode("ADMIN")
                .orElseThrow(() -> new IllegalStateException("未找到 admin 员工种子记录（V08 迁移）"));
        if (!StringUtils.hasText(props.getAdminPassword())
                || props.getAdminPassword().length() < 12) {
            throw new IllegalStateException(
                    "空库首次启动必须提供至少 12 位 BOOTSTRAP_ADMIN_PASSWORD；"
                            + "账号创建并完成首登改密后可移除此变量");
        }

        UserAccount user = new UserAccount();
        user.setEmployeeId(adminEmp.getId());
        user.setLoginAccount(props.getAdminLogin());
        user.setPasswordHash(passwordEncoder.encode(props.getAdminPassword()));
        user.setMustChangePassword(true);
        user.setStatus("active");
        user.setFailedAttempts(0);
        user.setSuperAdmin(true);  // ← 关键：标记超级管理员
        userRepo.save(user);

        Role adminRole = roleRepo.findByCode("admin")
                .orElseThrow(() -> new ApiException(ErrorCode.INTERNAL, "未找到 admin 角色"));
        UserRole ur = new UserRole();
        ur.setId(new UserRoleId(user.getId(), adminRole.getId()));
        userRoleRepo.save(ur);

        log.warn("已创建引导超管账号 [{}]（is_super_admin=true，不设置职务）—— 首次登录必须修改密码（一次性密码请尽快轮换）",
                props.getAdminLogin());
    }
}
