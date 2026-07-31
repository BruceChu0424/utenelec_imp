# 优腾电器官网 · 设计系统 (MASTER) — Cinema Dark

> 项目视觉宪法。所有页面、组件、后台均以此为准。建任何页面前先读此文件。
> 关联记忆: [[uten-website-multilang-cms]]

---

## 1. 品牌定位

- **企业**: 中山市优腾电器有限公司 (Uten Electrical) — 25 年专注安全墙壁开关 / 插座 / 面板，高新技术企业，**有外贸出口**。
- **品牌主色**: `#009A8E`（青绿 / teal）。
- **Logo**:
  - `logo_name.png` — 横向 wordmark「UTEN ELEC」，UTEN 青绿 + ELEC 灰，**透明背景**，深浅色通用。
  - `logo_ip.png` — 戴黄色安全帽的 IP 吉祥物，**圆形深青绿底**（非透明），作 Hero 发光徽章。
- **设计风格**: **Cinema Dark**（深色电影感）— 深空 + 环境光斑 + 玻璃态 + Expo 缓动，苹果式克制。

## 2. 设计原则

1. **克制（苹果风）** — 少而精，大量留白，单屏 1–2 个动效，不堆砌。
2. **电影质感** — 深空背景 + 漂移光斑 + 玻璃态卡片 + 银白渐变标题。
3. **品牌一致** — `#009A8E` 贯穿 accent / 光晕 / eyebrow / focus ring。
4. **可达性** — 对比度 AA/AAA、键盘焦点、`prefers-reduced-motion` 全局降级。
5. **内容可编辑** — 一切展示内容来自 CMS，前台零硬编码业务文案。

## 3. 色彩系统

> 默认深色（Cinema Dark）。浅色 token 保留作主题切换兜底。

### 深色 Tokens (`.dark`，默认)

| Token | HSL | Hex | 用途 |
|---|---|---|---|
| `--background` | `228 33% 4%` | `#06080C` | 深空底色（不用纯黑 #000，防 OLED smear） |
| `--background-elevated` | `224 26% 7%` | `#0E1117` | 抬升层（banner / section 交替） |
| `--foreground` | `210 40% 97%` | `#FAFCFF` | 银白正文 / 标题 |
| `--accent` | `174 100% 36%` | `#009A8E` 区 | 品牌青绿 — CTA / eyebrow / 光晕 |
| `--accent-soft` | `174 85% 60%` | 亮 teal | 深色背景上的强调文字 / 渐变 |
| `--primary` | `215 35% 13%` | `#15212E` navy | **深色块**（footer / banner / sidebar） |
| `--primary-foreground` | `210 40% 97%` | 银白 | 深块上的文字 |
| `--card` | `224 30% 6%` | `#0B0E14` | 卡片底（玻璃态覆盖） |
| `--border` | `220 16% 17%` | — | 发丝边框 |
| `--muted-foreground` | `215 18% 62%` | — | 次级文字 |
| `--ring` | `174 90% 50%` | teal | 焦点环 |

> ⚠️ **关键约束**: 深色下 `--primary` 必须是 navy（深块），**不能设成银白（前景色）**——否则所有 `bg-primary` 区块（footer/banner/sidebar）会变成刺眼银白。曾踩过。

**对比度**: `#009A8E` on 深空 = **5.74:1**（AAA 正文）；白字 on teal 按钮 = 3.49:1（AA 大字/UI）。

### 玻璃态

```css
.dark .card-uten {
  background: linear-gradient(180deg, rgba(255,255,255,.045), rgba(255,255,255,.012));
  border: 1px solid rgba(255,255,255,.08);  /* 发丝 */
}
.glass { background: rgba(255,255,255,.05); backdrop-filter: blur(20px) saturate(140%); }
```

## 4. 字体系统

- **标题**: `Lexend`（拉丁）— 现代友好、可读性极佳。
- **正文**: `Source Sans 3`（拉丁）— 高可读、专业。
- **中文**: 系统字体栈兜底（PingFang SC / Microsoft YaHei / Hiragino Sans GB）。
- **加载方式**: 运行时 `<link>`（layout `<head>`），**不用 `next/font/google`**（国内构建时下载会失败）。

```css
--font-heading: 'Lexend', 'PingFang SC', 'Microsoft YaHei', system-ui, sans-serif;
--font-body: 'Source Sans 3', 'PingFang SC', 'Microsoft YaHei', system-ui, sans-serif;
```

### 字号阶

| Token | 用途 |
|---|---|
| `text-hero` | Hero 主标题 `clamp(3rem, 8vw, 6rem)` |
| `text-display` | 大标题 `clamp(2.75rem, 7vw, 5rem)` |
| `text-4xl/3xl` | 页面/区块标题 |
| `text-base` | 正文 16px（移动端最小） |

## 5. 间距 / 圆角 / 阴影

- **间距**: 8pt 节奏（4/8/12/16/24/32/48/64/96）。
- **圆角**: `--radius` 0.875rem（14px）；卡片 16px；按钮 12px。
- **阴影**: 深色用 `lg` = `0 24px 60px -16px rgba(0,0,0,.5)`；`glow` = accent 光晕。
- **容器**: `max-w-7xl` (1280px)。

## 6. 动效系统

> 统一 **Expo 缓动** `cubic-bezier(0.16, 1, 0.3, 1)`，时长偏慢（500–800ms）更显高级。

| 组件 | 说明 | 文件 |
|---|---|---|
| `Reveal` | 滚动进入视口浮现（fade + translate-y），支持 `delay` 做 stagger 序列 | `components/motion/Reveal.tsx` |
| `CountUp` | 数字 0→目标计数（ease-out cubic），智能解析「25+」「$20」 | `components/motion/CountUp.tsx` |
| `ambient-blob` + `animate-blob` | 环境光斑（blur 圆 + 18s 漂移） | globals.css |
| `float` | 产品/IP 形象呼吸悬浮 6s | tailwind keyframes |

**铁律**:
- 只动 `transform` / `opacity`，**禁止动画 width/height**。
- **必须** `prefers-reduced-motion` 全局降级（globals.css 已加 + 组件内判断）。
- **克制**: 单屏最多 1–2 个主动效，不是动得越多越高级。

## 7. 组件规范

| 组件 | 规范 |
|---|---|
| `card-uten` | 玻璃态深色卡，hover `-translate-y` + `border-accent/40` |
| `btn-accent` | teal 实心 + hover 光晕 `box-shadow accent/.55` |
| `btn-primary` | 银白实心（深字） |
| `btn-outline` | 发丝边框，hover `border-accent/50` |
| `eyebrow` | 小标签，带前置短线 `::before`，uppercase tracking-[0.28em] text-accent |
| `text-gradient` | 银白竖向渐变（标题用） |
| `text-gradient-accent` | teal 渐变（数字/强调） |
| 图标 | Lucide，统一 1.5px stroke，**禁止 emoji** |

## 8. 页面结构

### 首页（苹果风，克制少量）

`Hero`（全屏电影：光斑 + 银白渐变巨字 + IP 徽章悬浮发光 + 光晕按钮 + 滚动指示）
→ `Stats`（CountUp 数字）
→ **`Featured`（4 款精选产品 · 2×2 大卡 · 大图大留白）**
→ `Craft`（4 大工艺）
→ `About`（双栏 + 图墙）
→ `Cases`（样板工程）
→ `News`（3 条）
→ `CTA`（合作号召，光斑卡）

> 首页产品区是**少量精选大卡**（苹果风），不是密集罗列。完整 65 款在「产品中心」。精选由 `getLatestProducts(4)` 取最新有图产品，可改为后台 featured。

### 其他页

统一**电影 banner**（background-elevated + 光斑 + eyebrow + `text-gradient` 标题）+ 内容区。

## 9. Logo 用法

| 位置 | 文件 | 尺寸 |
|---|---|---|
| 页头 / 页脚 / 登录 / 后台 | `logo_name.png` | h-6 ~ h-7（横向 wordmark） |
| Hero 右侧 | `logo_ip.png` | 圆形 IP 徽章 + accent 光晕 + `animate-float` |

不改色、不改比例、不加描边。文件在 `public/images/logo/`。

## 10. 反模式（禁止）

- ❌ 纯黑 `#000` 背景（OLED smear）— 用 `#06080C`。
- ❌ 深色下 `--primary` 设银白 — `bg-primary` 会刺眼。
- ❌ 动画 `width/height/top/left`。
- ❌ 业务文案硬编码（必须走 CMS / messages）。
- ❌ Emoji 当图标 / `next/font/google` / 紫粉 AI 渐变。
- ❌ 密集罗列（首页要苹果风克制）。
- ❌ 忽略 `prefers-reduced-motion`。

## 11. 交付前检查

- [ ] Lucide SVG 图标统一 stroke；无 emoji。
- [ ] 玻璃态卡 + 发丝边框 + hover 微浮。
- [ ] 焦点环 teal 可见；键盘 Tab 顺序正确。
- [ ] 银白正文对比度 ≥ 4.5:1（深色）。
- [ ] `prefers-reduced-motion` 降级生效。
- [ ] 375 / 768 / 1024 / 1440 四档响应式。
- [ ] 业务内容来自 CMS；UI 文案来自 messages。
- [ ] 动效克制（单屏 1–2 个）。
