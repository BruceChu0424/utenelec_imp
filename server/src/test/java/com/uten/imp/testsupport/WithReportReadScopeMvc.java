package com.uten.imp.testsupport;

import com.uten.imp.common.export.ExportProjectionAccessGuard;
import com.uten.imp.security.ReadScopeVersionAuthority;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/** MVC slices retain the real publication advice with explicit authority collaborators. */
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
@MockitoBean(types = {ReadScopeVersionAuthority.class, ExportProjectionAccessGuard.class})
public @interface WithReportReadScopeMvc {}
