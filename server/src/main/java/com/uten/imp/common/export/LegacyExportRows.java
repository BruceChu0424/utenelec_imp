package com.uten.imp.common.export;

import java.lang.annotation.*;

/** A reviewed existing single-object file contract; collection exports include all results. */
@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
public @interface LegacyExportRows { int value(); }
