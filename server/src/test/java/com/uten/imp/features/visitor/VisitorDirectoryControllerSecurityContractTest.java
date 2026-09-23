package com.uten.imp.features.visitor;

import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;

import java.lang.reflect.Method;
import java.util.Arrays;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * security-08 / permissions-13：访客选择接待人的目录只对访客主体开放，只能按姓名先搜再选；
 * 不再提供部门树与按部门列举(外部自助注册账号翻不出公司名册)。访客码独立命名空间，
 * 不进员工权限目录。
 */
class VisitorDirectoryControllerSecurityContractTest {

    @Test
    void directoryIsVisitorOnlyAndSearchOnly() {
        PreAuthorize classGuard = VisitorDirectoryController.class.getAnnotation(PreAuthorize.class);
        assertThat(classGuard.value())
                .contains("principal.visitor")
                .contains("hasAuthority('" + VisitorAuthorities.APPLY + "')");

        List<Method> endpoints = Arrays.stream(VisitorDirectoryController.class.getDeclaredMethods())
                .filter(method -> method.isAnnotationPresent(GetMapping.class))
                .toList();
        assertThat(endpoints).hasSize(1);
        assertThat(endpoints.getFirst().getAnnotation(GetMapping.class).value()).containsExactly("/employees");
        // 只接受一个姓名关键字(另一个参数是取来源地址做限流的请求对象)，不接受部门或编号。
        assertThat(Arrays.stream(endpoints.getFirst().getParameters())
                .filter(parameter -> parameter.isAnnotationPresent(
                        org.springframework.web.bind.annotation.RequestParam.class))
                .map(parameter -> parameter.getAnnotation(
                        org.springframework.web.bind.annotation.RequestParam.class))
                .toList()).hasSize(1);
        assertThat(endpoints.getFirst().getParameterTypes())
                .containsExactly(String.class, jakarta.servlet.http.HttpServletRequest.class);
    }

    @Test
    void visitorAuthoritiesLiveInTheirOwnNamespace() {
        assertThat(VisitorAuthorities.ALL).isNotEmpty()
                .allMatch(code -> code.startsWith(VisitorAuthorities.NAMESPACE));
    }
}
