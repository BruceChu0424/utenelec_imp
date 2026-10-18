# 官网开发规则

前端页面、组件、响应式、交互与设计文档默认使用 `frontend-design`，先读 `C:/Users/bruce/.agents/skills/frontend-design/SKILL.md`（其他环境 `~/.agents/skills/frontend-design/SKILL.md`）。不自动使用 ui-ux-pro-max。遵守仓库根 AGENTS 与项目规范，保留 Uten 品牌、业务权限、来源身份及发布约束。

官网是企业与产品展示站，只提供业务联系，不增加购物车、支付或下单。公开页面不得直接依赖 IMP 在线。所有询盘通过持久投递与回执进入销售工作台；不能把模拟数据或发送日志当成送达事实。阿里云部署须在本地验收完成后另获用户确认。

<!-- BEGIN:nextjs-agent-rules -->

## This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` (resolved from this file's directory; in monorepos the `next` package may not be visible from the repo root) before writing any code. Heed deprecation notices.

This block is written and re-added by `next dev` — verify at `node_modules/next/dist/server/lib/generate-agent-files.js`. Removing it from a diff only re-creates the uncommitted change; committing it with your work keeps the tree clean.

<!-- END:nextjs-agent-rules -->
