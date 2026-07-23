# UtenBrandMascot

> 文件：`lib/components/brand/uten_brand_mascot.dart`
> 分类：Brand Identity · Phase 0
> 资产：`assets/images/logo_ip.png`（747×778，8-bit RGBA，≈1:1）

## 一、用途

品牌 IP / 吉祥物（戴黄色安全帽、手持电子工具的"德国工程师"卡通形象），用于大画幅品牌露出：

| 场景 | 用什么 |
|---|---|
| 启动屏全屏铺底 | `UtenBrandMascot.background()` |
| 登录页侧图（左右分栏） | `UtenBrandMascot(width: 280, height: 280)` |
| About 页头部 | `UtenBrandMascot(width: 200, height: 200)` |
| 空状态装饰 | `UtenBrandMascot.size(120)` |

**何时不用：**

- 不要在窄卡片里塞 —— 比例 ≈1:1，画面信息太密会糊
- 不要在 `Row` 里和其他控件硬挤 —— 用 `UtenBrandMascot.background()` 让它独占空间

## 二、API（参数表）

| 参数 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `key` | `Key?` | `null` |  |
| `width` | `double?` | `null` | 约束宽度。null 时由 intrinsic 大小决定 |
| `height` | `double?` | `null` | 约束高度。 |
| `fit` | `BoxFit` | `BoxFit.contain` | 内部 Image 的填充模式 |
| `semanticLabel` | `String` | `'Uten 优腾 德国工程师'` | 屏幕阅读器朗读 |

四种构造方式：

| 构造 | 用途 | 尺寸 |
|---|---|---|
| `UtenBrandMascot()` | 原图尺寸 | 747 × 778（intrinsic） |
| `UtenBrandMascot.size(200)` | 正方形 | 200 × 200 |
| `UtenBrandMascot(width: 280, height: 280)` | 显式宽高 | 280 × 280 |
| `UtenBrandMascot.background()` | 铺满父空间 | `double.infinity` |

## 三、响应式行为

无自动断点适配。调用方根据布局需要传 width/height，或用 `.background()` 铺底。

## 四、性能档行为

无动画 / 无模糊，三档一致。`gaplessPlayback: true` 避免加载闪烁。

## 五、主题与国际化适配

- 不跟主题切色（IP 形象固定）；浅色 / 深色模式都用同一张图
- 浅色背景上需要注意：图为深色块（青绿底），适合深底或中性底，**不适合白底**（对比太硬）
- `semanticLabel` 中文业务标识，i18n 暂不参与

## 六、示例代码

**启动屏全屏铺底：**

```dart
Scaffold(
  body: ColoredBox(
    color: UtenColors.deepGreen,
    child: const UtenBrandMascot.background(),
  ),
)
```

**About 页头部（200×200）：**

```dart
Column(
  crossAxisAlignment: CrossAxisAlignment.center,
  children: [
    const UtenBrandMascot.size(200),
    const SizedBox(height: 16),
    Text('关于优腾', style: theme.textTheme.headlineSmall),
  ],
)
```

**登录页侧图（大屏左右分栏）：**

```dart
Row(
  children: [
    Expanded(
      child: Container(
        color: UtenColors.deepGreen,
        child: const Center(
          child: UtenBrandMascot(width: 320, height: 320),
        ),
      ),
    ),
    Expanded(child: _buildLoginForm()),
  ],
)
```

**空状态装饰：**

```dart
UtenEmpty(
  icon: const UtenBrandMascot.size(120),
  title: '暂无访客',
  message: '当前没有需要您处理的访客申请',
)
```

## 七、实现要点

- 资产路径来自 `UtenAssets.logoIp`，禁止业务代码里硬编码 `'assets/images/logo_ip.png'`
- `background()` 用 `SizedBox.expand` 语义而不是传 `width: double.infinity, height: double.infinity`；后者会在 `Stack` 里翻车（想要 "尽量大但不超出父约束" 的语义）。`expand` 更安全
- 内部先构造 `Image`，再外层 `SizedBox` 约束 —— 顺序很重要：`SizedBox` 包 `Image` 会得到固定框，加载延迟时图片缩放动画可控；`Image` 包 `SizedBox` 会先按 intrinsic 撑开布局，再被约束裁剪
- `UtenBrandMascot()` 不传 width/height 时按 `747×778` 原图渲染 —— 这是有意为之，让 "展示完整 IP" 这种用例（如 About 页）少敲代码
