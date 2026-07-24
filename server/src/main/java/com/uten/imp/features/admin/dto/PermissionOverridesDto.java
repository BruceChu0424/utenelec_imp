package com.uten.imp.features.admin.dto;

import java.util.List;

/** 个人权限点覆盖（GET 响应 / PUT 请求共用；整体替换语义）。 */
public record PermissionOverridesDto(List<String> grants, List<String> revokes) {}
