package com.uten.imp.common.validation;

import jakarta.validation.Constraint;
import jakarta.validation.Payload;
import java.lang.annotation.*;

/** HTTP quantity format shares the native service boundary; sign/null rules stay at each caller. */
@Documented
@Constraint(validatedBy=DocumentQuantityValidator.class)
@Target({ElementType.FIELD,ElementType.PARAMETER,ElementType.RECORD_COMPONENT,ElementType.TYPE_USE,ElementType.METHOD})
@Retention(RetentionPolicy.RUNTIME)
public @interface DocumentQuantity {
    String message() default "数量超出可无损保存范围（最多40位整数、24位有效小数）";
    Class<?>[] groups() default {};
    Class<? extends Payload>[] payload() default {};
}
