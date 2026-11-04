package com.uten.imp.common.validation;

import jakarta.validation.Constraint;
import jakarta.validation.Payload;
import java.lang.annotation.*;

/** Native finite amount format; each caller retains its own sign and rate rules. */
@Documented
@Constraint(validatedBy=DocumentAmountValidator.class)
@Target({ElementType.FIELD,ElementType.PARAMETER,ElementType.RECORD_COMPONENT,ElementType.TYPE_USE,ElementType.METHOD})
@Retention(RetentionPolicy.RUNTIME)
public @interface DocumentAmount {
    String message() default "金额超出可无损保存范围（最多40位整数、24位有效小数）";
    Class<?>[] groups() default {};
    Class<? extends Payload>[] payload() default {};
}
