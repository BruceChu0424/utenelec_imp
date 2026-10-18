package com.uten.imp.security;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/**
 * A read-only personal task/count endpoint, evaluated before method security using
 * actual grants rather than the super-administrator catalog expansion.
 * Ordinary document browsing and commands must not use this annotation.
 */
@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
public @interface BusinessTaskRead {
}
