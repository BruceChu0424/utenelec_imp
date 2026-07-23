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
            log.info("引导超管账号已存在，跳过");
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
        userRepo.save(user);

        Role adminRole = roleRepo.findByCode("admin")
                .orElseThrow(() -> new ApiException(ErrorCode.INTERNAL, "未找到 admin 角色"));
        UserRole ur = new UserRole();
        ur.setId(new UserRoleId(user.getId(), adminRole.getId()));
        userRoleRepo.save(ur);

        log.warn("已创建引导超管账号 [{}] —— 首次登录必须修改密码（一次性密码请尽快轮换）", props.getAdminLogin());
    }
}
