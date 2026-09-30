package com.uten.imp.common.platformcolumns;

import java.lang.annotation.*;

/** Atomic field preservation for authorized domain saves; field changes require pre-save write access. */
@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
public @interface PlatformColumnDocumentSave {
    String scope();
    int requestArgument() default 0;
    int documentIdArgument() default -1;
    Mapping mapping() default Mapping.ORDERED;
    /** Domain-declared measurement basis, e.g. stock counts use countWeight/countQty before book qty. */
    String[] quantityFields() default {"qty"};
    enum Mapping { ORDERED, DOMAIN_LINEAGE }
}
