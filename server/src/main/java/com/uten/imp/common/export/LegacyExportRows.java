package com.uten.imp.common.export;

import java.lang.annotation.*;

/** A reviewed existing single-object file limit; collection exports default to 500. */
@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
public @interface LegacyExportRows { int value(); }
