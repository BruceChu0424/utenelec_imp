package com.uten.imp.features.org.department.staffpermission.dto;

/**
 * 旧版个人权限覆盖请求体。该路由现在是兼容占位：无论 effect 取值如何，
 * 服务端一律返回 403，不再读写 user_permission_overrides。
 */
public record SetStaffOverrideRequest(String effect) {}
