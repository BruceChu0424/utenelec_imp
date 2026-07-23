package com.uten.imp.features.auth;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.BootstrapProperties;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.rbac.*;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.core.annotation.Order;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Component;

/**
 * 首次启动创建引导超管账号（admin）。
 * <p>
 * 该账号语义上是"超级管理员"：
 * <ul>
 *   <li>{@code users.is_super_admin = true}（V16 字段）</li>
 *   <li>不设置 position（V08 INSERT 不写）</li>
 *   <li>不依赖 role_permissions 是否齐全——AuthService.permsOf() 在 isSuperAdmin=true 时
 *       直接返回 permissions 表全量</li>
 * </ul>
 * 密码取自 BOOTSTRAP_ADMIN_PASSWORD，Argon2id 哈希入库，must_change_password=true。
 * 已存在则跳过。SQL 迁移已种入 admin 员工档案（code=ADMIN）。
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
            // 升级路径：把已存在 admin 的 is_super_admin 置 true（幂等）
            userRepo.findByLoginAccount(props.getAdminLogin()).ifPresent(u -> {
                if (!u.isSuperAdmin()) {
                    u.setSuperAdmin(true);
                    userRepo.save(u);
                    log.warn("已为现有账号 [{}] 标记 is_super_admin=true（幂等升级）", props.getAdminLogin());
                }
            });
            return;
        }
        Employee adminEmp = employeeRepo.findByCode("ADMIN")
                .orElseThrow(() -> new IllegalStateException("未找到 admin 员工种子记录（V08 迁移）"));

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
