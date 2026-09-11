# UtenWordmarkLogo

> 文件：`lib/components/brand/uten_wordmark_logo.dart`
> 分类：Brand Identity · Phase 0
> 资产：`assets/images/logo_name.png`（405×74，8-bit RGBA，≈5.47:1）

## 一、用途

横向品牌名锁版（**UTEN** + **ELEC**），用于任何需要露出品牌名但空间窄的地方：

| 场景 | 用什么 |
|---|---|
| 入口选择页顶部 | `UtenWordmarkLogo(width: 280/360 按断点)`（窄屏 280×~51 / 大屏 360×~66，2026-09-10 放大为主视觉） |
| 登录页顶部 | `UtenWordmarkLogo(width: 220, height: 220/(405/74))`（220×~40） |
| 启动屏 | `UtenWordmarkLogo.splash()`（320×~58） |
| 卡片内 / 行内 / Avatar 旁 | `UtenWordmarkLogo.compact()`（120×~22） |
| 大屏 hero banner | `UtenWordmarkLogo(width: 360, height: 66)` |

**何时不用：**

- 不要和 `AppBar.title` 同时出现（视觉重复）
- 不要直接 `Image.asset('assets/images/logo_name.png')` —— 路径集中管理是禁止散落硬编码

## 二、API（参数表）

| 参数 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `key` | `Key?` | `null` |  |
| `width` | `double` | `240` | 渲染宽度。组件内 `BoxFit.contain` 保证纵横比不失真 |
| `height` | `double` | `44` | 渲染高度。 |
| `semanticLabel` | `String` | `'Uten ELEC'` | 屏幕阅读器朗读（无障碍） |
| `gaplessPlayback` | `bool` | `true` | 图像未加载完成前保留上一帧，不闪烁 |

三种构造方式：

| 构造 | 用途 | 尺寸 |
|---|---|---|
| `UtenWordmarkLogo()` | 默认 | 240 × 44 |
| `UtenWordmarkLogo.splash()` | 启动屏 | 320 × ~58 |
| `UtenWordmarkLogo.compact()` | 卡片/行内 | 120 × ~22 |

## 三、响应式行为

无三档差异。图像本身就是按最终尺寸矢量渲染（资产本身是位图，但组件不自动按断点改尺寸，调用方按需传 width/height）。

## 四、性能档行为

无动画 / 无模糊，三档一致。`gaplessPlayback: true` 避免热重载或异步加载时画面闪烁。

## 五、主题与国际化适配

- 不跟主题切色（品牌色固定），浅色 / 深色模式都用同一张图
- 背景透明，深色背景（slate-900 等）上视觉对比最佳；浅色背景如需使用，需要先验证可读性
- `semanticLabel` 是英文业务标识，i18n 不参与

## 六、示例代码

**入口选择页（默认尺寸）：**

```dart
const Center(child: UtenWordmarkLogo()),
```

**启动屏（用 splash 预设）：**

```dart
Scaffold(
  body: Container(
    color: Colors.black,
    child: const Center(child: UtenWordmarkLogo.splash()),
  ),
)
```

**自定义尺寸：** width / height 一起传，组件内 `BoxFit.contain` 自动保持比例：

```dart
SizedBox(
  width: 360,
  child: const UtenWordmarkLogo(width: 360, height: 66),
)
```

**Avatar 旁的小锁版：**

```dart
ListTile(
  leading: const CircleAvatar(child: Icon(Icons.person)),
  title: const Text('张三'),
  subtitle: Row(
    children: [
      const UtenWordmarkLogo.compact(),
      const SizedBox(width: 8),
      Text(l10n.profileDepartment),
    ],
  ),
)
```

## 七、实现要点

- 资产路径来自 `UtenAssets.logoName`，禁止业务代码里硬编码 `'assets/images/logo_name.png'`
- 比例 5.47:1 是写死的（`320 / (405 / 74)`），不允许用算式常量化 —— 公式太啰嗦，常量可读
- 颜色仅取自图片本身（青绿 + 灰），不与 `UtenColors` 联动 —— 品牌资产应该和代码主题解耦
