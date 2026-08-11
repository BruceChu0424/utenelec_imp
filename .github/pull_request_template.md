## 变更目的

<!-- 说明业务目标、用户影响和为什么需要这次变更。 -->

## 范围

- 包含：
- 不包含：
- 关联 Issue / ADR / SOP：

## 全链影响

- [ ] UI / 交互已更新或不适用
- [ ] API / 服务端权限已更新或不适用
- [ ] 事务、持久化、审计事实已更新或不适用
- [ ] Flyway / 数据兼容 / 回滚已说明或不适用
- [ ] 相关项目文档已同步

## 验证

- [ ] 已检查 `git diff --cached --check`
- [ ] 已运行本次变更的定向测试
- [ ] Flutter format / analyze / test / Web build 已通过或已说明未验证原因
- [ ] Java 21 `UTEN_RUN_DB_TESTS=true mvn verify` 已通过或已说明未验证原因
- [ ] 修改 `website/` 时，Website lint / 全部测试 / build 已通过或已说明未验证原因
- [ ] 未提交真实 `.env`、密钥、业务数据、备份、构建产物或运行时媒体
- [ ] Quality Gate、CodeQL、Dependency Vulnerability Scan 本次远端运行已通过

验证命令与结果：

```text

```

## 风险与回滚

- 数据/金额/库存/权限/迁移风险：
- 回滚或受控反向方案：
- 仍未验证的事项：

## 合并确认

- [ ] 本 PR 只包含一个明确业务目标，不是长期快照/总包 PR
- [ ] 来源分支已同步最新 `origin/main`
- [ ] 所有 Review 意见已处理
- [ ] 不通过直接推送或 force push `main` 绕过失败门禁
