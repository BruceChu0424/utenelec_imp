package com.uten.imp.common.report;

import java.lang.annotation.*;

/** Explicit POST read contract; preserves report metadata and publication fences. */
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.METHOD)
public @interface ReadOnlyReportQuery { }
