"""Generate native WPF resources from the owning Flutter light-theme sources.

Only the supported Dart constant/call grammar is evaluated. Unsupported or
missing source expressions fail closed; there is no independent WPF palette.
Running without arguments checks files without writing or using the network.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from decimal import Decimal, ROUND_HALF_UP
import hashlib
import json
from pathlib import Path
import re
import sys

GENERATOR = "clients/windows_legacy/tools/sync_design_tokens.py"
RESOURCE = "clients/windows_legacy/Uten.Legacy.Desktop/Themes/Uten.Tokens.g.xaml"
PROVENANCE = "clients/windows_legacy/design-token-provenance.json"
SOURCES = (
    "lib/core/theme/uten_tokens.dart",
    "lib/core/theme/uten_colors.dart",
    "lib/core/theme/light_theme.dart",
    "lib/core/theme/uten_typography.dart",
    "lib/shared/widgets/desktop_window_host.dart",
    "lib/features/auth/widgets/desktop_login_layout.dart",
)
PUBLIC_WINDOW_CONTROLS = "lib/components/buttons/uten_close_button.dart"


def source_paths(root: Path) -> tuple[str, ...]:
    """Follow the actual owner without making an absent public widget mandatory
    for a clean historical context. Presence selects strict public parsing."""
    return SOURCES + ((PUBLIC_WINDOW_CONTROLS,) if (root / PUBLIC_WINDOW_CONTROLS).is_file() else ())

SPACING_ROLES = ("s2", "s4", "s6", "s8", "s12", "s16", "s20", "s24", "s32", "s40", "s48")


class TokenError(ValueError):
    pass


def masked_code(text: str) -> str:
    """Mask comments and strings, retaining offsets and line numbers."""
    output = list(text)
    index = 0
    while index < len(text):
        start = index
        if text.startswith("//", index):
            end = text.find("\n", index)
            index = len(text) if end < 0 else end
        elif text.startswith("/*", index):
            depth, index = 1, index + 2
            while depth and index < len(text):
                if text.startswith("/*", index):
                    depth, index = depth + 1, index + 2
                elif text.startswith("*/", index):
                    depth, index = depth - 1, index + 2
                else:
                    index += 1
            if depth:
                raise TokenError("Unterminated Dart comment")
        elif text[index] in "\"'":
            quote = text[index] * (3 if text.startswith(text[index] * 3, index) else 1)
            index += len(quote)
            while index < len(text) and not text.startswith(quote, index):
                index += 2 if text[index] == "\\" else 1
            if index >= len(text):
                raise TokenError("Unterminated Dart string")
            index += len(quote)
        else:
            index += 1
            continue
        for position in range(start, min(index, len(text))):
            if output[position] not in "\r\n":
                output[position] = " "
    return "".join(output)


def closing(code: str, opening: int) -> int:
    pairs = {"(": ")", "[": "]", "{": "}"}
    stack = [pairs[code[opening]]]
    for index in range(opening + 1, len(code)):
        value = code[index]
        if value in pairs:
            stack.append(pairs[value])
        elif value in pairs.values():
            if not stack or value != stack.pop():
                raise TokenError("Unbalanced Dart expression")
            if not stack:
                return index
    raise TokenError("Unclosed Dart expression")


def segments(code: str, start: int, end: int):
    cursor, part = start, start
    while cursor < end:
        if code[cursor] in "([{":
            cursor = closing(code, cursor) + 1
        elif code[cursor] == ",":
            if code[part:cursor].strip():
                yield part, cursor
            part, cursor = cursor + 1, cursor + 1
        else:
            cursor += 1
    if code[part:end].strip():
        yield part, end


@dataclass(frozen=True)
class Declaration:
    symbol: str
    source: str
    line: int
    expression: str
    context: str | None = None

    def evidence(self):
        return {"symbol": self.symbol, "source": self.source, "line": self.line,
                "expression": self.expression}


class DartTokens:
    def __init__(self, texts: dict[str, str]):
        self.texts = texts
        self.code = {path: masked_code(text) for path, text in texts.items()}
        self.declarations: dict[str, Declaration] = {}
        self.classes = {}
        for path, code in self.code.items():
            for match in re.finditer(r"\bclass\s+(\w+)\b[^{}]*\{", code):
                name, start = match.group(1), match.end() - 1
                end = closing(code, start)
                self.classes[name] = (path, start, end)
                pattern = r"\bstatic\s+const\s+(?:(?:double|Color|EdgeInsets)\s+)?(\w+)\s*=\s*([^;]+);"
                for entry in re.finditer(pattern, code[start + 1:end]):
                    offset = start + 1 + entry.start(2)
                    self.bind(name + "." + entry.group(1), path, offset,
                              self.texts[path][offset:start + 1 + entry.end(2)].strip(), name)
        self._bind_theme()

    def bind(self, symbol, path, offset, expression, context=None):
        if symbol in self.declarations:
            raise TokenError("Duplicate source token: " + symbol)
        self.declarations[symbol] = Declaration(symbol, path,
            self.texts[path].count("\n", 0, offset) + 1, expression, context)

    def call(self, path, pattern, scope=None):
        code = self.code[path]
        start, end = (0, len(code)) if scope is None else scope
        matches = list(re.finditer(pattern, code[start:end], re.S))
        if len(matches) != 1:
            raise TokenError(f"Expected one owning call: {path}: {pattern}")
        opening = start + matches[0].end() - 1
        end = closing(code, opening)
        result = {}
        for first, last in segments(code, opening + 1, end):
            item = re.match(r"\s*(\w+)\s*:\s*", code[first:last])
            if item:
                name, offset = item.group(1), first + item.end()
                if name in result:
                    raise TokenError("Duplicate named argument: " + name)
                result[name] = (offset, self.texts[path][offset:last].strip())
        return result

    def bind_arguments(self, prefix, path, arguments):
        for name, (offset, expression) in arguments.items():
            self.bind(prefix + "." + name, path, offset, expression)

    def _bind_theme(self):
        light = SOURCES[2]
        self.bind_arguments("LightTheme.colorScheme", light,
            self.call(light, r"const\s+colorScheme\s*=\s*ColorScheme\s*\("))
        theme = self.call(light, r"final\s+base\s*=\s*ThemeData\s*\(")
        if theme.get("colorScheme", (None, None))[1] != "colorScheme":
            raise TokenError("Light ThemeData no longer uses the parsed colorScheme")
        self.bind_arguments("LightTheme", light, theme)
        for role, owner in (("FilledButton", "FilledButton"), ("OutlinedButton", "OutlinedButton")):
            name = role[0].lower() + role[1:]
            self.bind_arguments("LightTheme." + name, light,
                self.call(light, name + r"Theme\s*:\s*" + owner + r"ThemeData\s*\(\s*style\s*:\s*" + owner + r"\.styleFrom\s*\("))

        typography = SOURCES[3]
        helper = self.call(typography, r"TextStyle\s+text\s*\([^)]*\)\s*=>\s*TextStyle\s*\(")
        if helper.get("fontSize", (None, None))[1] != "size":
            raise TokenError("Unsupported text helper: fontSize must use its size argument")
        roles = self.call(typography, r"return\s+TextTheme\s*\(")
        for name, (offset, expression) in roles.items():
            match = re.fullmatch(r"text\s*\(\s*([^,]+),[\s\S]*\)", expression)
            if not match:
                raise TokenError("Unsupported typography role: " + name)
            self.bind("UtenTextTheme." + name + ".fontSize", typography, offset,
                      match.group(1).strip())

        caption = SOURCES[4]
        if PUBLIC_WINDOW_CONTROLS in self.texts:
            self._bind_public_caption(caption)
            private_calls = ()
        else:
            private_calls = (
                ("_WindowButton", "Caption.hit", r"=>\s*SizedBox\s*\("),
                ("_WindowButton", "Caption.circle", r"icon\s*:\s*Container\s*\("),
                ("_WindowButton", "Caption.icon", r"child\s*:\s*Icon\s*\("),
                ("_DesktopWindowControls", "Caption.close", r"final\s+close\s*=\s*_WindowButton\s*\("),
                ("_DesktopWindowControls", "Caption.minimize", r"final\s+minimize\s*=\s*_WindowButton\s*\("),
            )
        for name, prefix, pattern in (*private_calls,
            ("_DesktopWindowControls", "Caption.layout", r"child\s*:\s*Padding\s*\(")):
            path, start, end = self.class_scope(name)
            if path != caption:
                raise TokenError("Caption owner moved unexpectedly")
            self.bind_arguments(prefix, caption, self.call(path, pattern, (start, end)))

        login = SOURCES[5]
        path, start, end = self.class_scope("_DesktopBrandPanel")
        if path != login or not re.search(r"final\s+dark\s*=\s*theme\.brightness\s*==\s*Brightness\.dark\s*;", self.code[path][start:end]):
            raise TokenError("Unsupported desktop login brightness selection")
        match = re.search(r"final\s+base\s*=\s*(Color\.alphaBlend\([\s\S]*?\))\s*;", self.code[path][start:end])
        if not match:
            raise TokenError("Desktop login brand surface source is missing")
        offset = start + match.start(1)
        self.bind("DesktopLogin.brandSurface", login, offset,
                  self.texts[login][offset:start + match.end(1)].strip())

    def _bind_public_caption(self, caption):
        public = PUBLIC_WINDOW_CONTROLS
        owner, start, end = self.class_scope("_DesktopWindowControls")
        if owner != caption or self.call(owner, r"UtenWindowControls\s*\(", (start, end)).get("native", (None, None))[1] != "true":
            raise TokenError("Native caption must use the public native window controls")
        owner, start, end = self.class_scope("_UtenWindowControlButtonState")
        if owner != public:
            raise TokenError("Public window-control owner moved unexpectedly")
        code = self.code[public][start:end]
        geometry = re.search(r"final\s+size\s*=\s*widget\.native\s*\?\s*const\s+Size\(\s*(UtenWindowControlButton\.\w+)\s*,\s*(UtenWindowControlButton\.\w+)\s*,?\s*\)\s*:\s*Size\.square", code)
        if geometry is None:
            raise TokenError("Unsupported public native hit geometry")
        for group, role in ((1, "width"), (2, "height")):
            self.bind("Caption.hit." + role, public, start + geometry.start(group), geometry.group(group))
        for role, control in (("close", "close"), ("minimize", "minimize")):
            matches = list(re.finditer(r"UtenWindowControl\." + control + r"\s*=>\s*(UtenColors\.\w+)\s*,", code))
            if len(matches) != 1:
                raise TokenError("Unsupported public window-control color: " + role)
            match = matches[0]
            self.bind("Caption." + role + ".backgroundColor", public, start + match.start(1), match.group(1))
        circle = self.call(public, r"icon\s*:\s*Container\s*\(", (start, end))
        icon = self.call(public, r"child\s*:\s*Icon\s*\(", (start, end))
        for arguments, argument, symbol in ((circle, "width", "Caption.circle.width"),
                (circle, "height", "Caption.circle.height"), (icon, "size", "Caption.icon.size")):
            offset, expression = arguments.get(argument, (None, ""))
            native = re.fullmatch(r"widget\.native\s*\?\s*([\w.]+)\s*:\s*[\w.]+", expression)
            if native is None:
                raise TokenError("Unsupported public native expression: " + symbol)
            self.bind(symbol, public, offset + native.start(1), native.group(1))

    def declaration(self, symbol):
        if symbol not in self.declarations:
            raise TokenError("Missing owning Dart token: " + symbol)
        return self.declarations[symbol]

    def class_scope(self, name):
        if name not in self.classes:
            raise TokenError("Missing owning Dart class: " + name)
        return self.classes[name]

    def resolve(self, symbol, kind, trail=()):
        if symbol in trail:
            raise TokenError("Dart token alias cycle: " + " -> ".join(trail + (symbol,)))
        declaration = self.declaration(symbol)
        expression = masked_code(declaration.expression).strip()
        alias = re.fullmatch(r"(?:([A-Za-z_]\w*)\.)?([A-Za-z_]\w*)", expression)
        if alias:
            context = alias.group(1) or declaration.context
            if not context:
                raise TokenError("Unqualified source alias: " + symbol)
            value, chain = self.resolve(context + "." + alias.group(2), kind, trail + (symbol,))
            return value, [declaration.evidence()] + chain
        if kind == "number" and re.fullmatch(r"\d+(?:\.\d+)?", expression):
            return Decimal(expression), [declaration.evidence()]
        color = re.fullmatch(r"(?:const\s+)?Color\s*\(\s*0x([0-9A-Fa-f]{8})\s*\)", expression)
        if kind == "color" and color:
            return "#" + color.group(1).upper(), [declaration.evidence()]
        raise TokenError(f"Unsupported {kind} expression for {symbol}: {declaration.expression}")

    def padding(self, symbol):
        declaration = self.declaration(symbol)
        match = re.fullmatch(r"(?:const\s+)?EdgeInsets\.symmetric\s*\(([\s\S]*)\)", masked_code(declaration.expression).strip())
        if not match:
            raise TokenError("Unsupported padding expression: " + symbol)
        axes = {}
        for entry in match.group(1).split(","):
            if not entry.strip():
                continue
            pair = re.fullmatch(r"\s*(horizontal|vertical)\s*:\s*([\s\S]+?)\s*", entry)
            if not pair or pair.group(1) in axes:
                raise TokenError("Unsupported padding argument: " + symbol)
            expression = pair.group(2)
            if re.fullmatch(r"\d+(?:\.\d+)?", expression):
                axes[pair.group(1)] = (Decimal(expression), [])
            else:
                reference = expression if "." in expression else str(declaration.context) + "." + expression
                axes[pair.group(1)] = self.resolve(reference, "number")
        # This is EdgeInsets.symmetric's defined constructor default, not a parse fallback.
        horizontal = axes.get("horizontal", (Decimal(0), []))
        vertical = axes.get("vertical", (Decimal(0), []))
        return (horizontal[0], vertical[0], horizontal[0], vertical[0]), [declaration.evidence()] + horizontal[1] + vertical[1]


def number(value: Decimal) -> str:
    return format(value.normalize(), "f")


def build_resources(tokens: DartTokens):
    resources = []

    def add(key, value_type, symbol, kind="number", note=None):
        value, chain = tokens.resolve(symbol, kind)
        text = number(value) if kind == "number" else value
        resources.append({"key": key, "type": value_type, "value": text,
                          "sourceRole": symbol, "resolution": chain, **({"note": note} if note else {})})

    for target, source in (("Xs", "xs"), ("Small", "sm"), ("Medium", "md"), ("Control", "control"),
                           ("Menu", "menu"), ("Table", "table"), ("Card", "card"), ("Dialog", "dialog"), ("Pill", "pill")):
        for suffix, value_type in (("", "CornerRadius"), ("Value", "Double")):
            add("Uten.Radius." + target + suffix, value_type, "UtenRadius." + source)
    for target, source in (("Compact", "compactHeight"), ("Standard", "standardHeight"),
                           ("Primary", "primaryHeight"), ("Input", "inputHeight"), ("Cell", "cellHeight")):
        add("Uten.Height." + target, "Double", "UtenControlMetrics." + source,
            note="Table editor control height; not a table row-height contract." if target == "Cell" else None)
    add("Uten.Height.Caption", "Double", "DesktopWindowHost.controlsHeight",
        note="Native caption/control strip; separate from form control metrics.")
    for role in SPACING_ROLES:
        tokens.declaration("UtenSpacing." + role)
    for symbol in tokens.declarations:
        if symbol.startswith("UtenSpacing."):
            name = symbol.split(".")[1]
            if not re.fullmatch(r"s\d+", name):
                raise TokenError("Unsupported spacing token name: " + name)
            add("Uten.Space." + name.capitalize(), "Double", symbol)
            add("Uten.Padding." + name.capitalize(), "Thickness", symbol)
    for key, symbol in (
        ("Background", "LightTheme.scaffoldBackgroundColor"), ("Surface", "LightTheme.colorScheme.surface"),
        ("Text", "LightTheme.colorScheme.onSurface"), ("Muted", "LightTheme.colorScheme.onSurfaceVariant"),
        ("Border", "LightTheme.colorScheme.outlineVariant"), ("PrimaryBrush", "LightTheme.colorScheme.primary"),
        ("PrimaryLight", "UtenColors.tealSurface"), ("Selected", "UtenColors.tableSelectedRow"),
        ("Error", "LightTheme.colorScheme.error"), ("Caption.Minimize", "Caption.minimize.backgroundColor"),
        ("Caption.Close", "Caption.close.backgroundColor"),
    ):
        add("Uten." + key, "SolidColorBrush", symbol, "color")
    for target, source in (("Body", "bodyMedium"), ("Value", "bodyMedium"), ("Caption", "bodySmall"),
                           ("Title", "titleLarge"), ("Subtitle", "titleMedium"), ("Heading", "headlineLarge"),
                           ("Input", "bodyLarge"), ("Compact", "bodyMedium")):
        add("Uten.FontSize." + target, "Double", "UtenTextTheme." + source + ".fontSize")
    for key, symbol in (("HitWidth", "Caption.hit.width"), ("Diameter", "Caption.circle.width"), ("IconSize", "Caption.icon.size")):
        add("Uten.Caption." + key, "Double", symbol)
    if tokens.resolve("Caption.circle.width", "number")[0] != tokens.resolve("Caption.circle.height", "number")[0]:
        raise TokenError("Caption circle width and height diverged; cannot export a diameter")
    if tokens.resolve("Caption.hit.height", "number")[0] != tokens.resolve("DesktopWindowHost.controlsHeight", "number")[0]:
        raise TokenError("Caption hit height and strip height diverged")
    button = tokens.padding("LightTheme.filledButton.padding")
    outlined = tokens.padding("LightTheme.outlinedButton.padding")
    if button[0] != outlined[0]:
        raise TokenError("Filled and outlined button padding diverged; split the WPF roles explicitly")
    for key, symbol in (("Button", "LightTheme.filledButton.padding"), ("Input", "UtenPageField.contentPadding"),
                        ("Filter", "UtenFilterRow.contentPadding"), ("CaptionHorizontal", "Caption.layout.padding")):
        values, evidence = tokens.padding(symbol)
        if key == "Button":
            evidence += outlined[1]
        resources.append({"key": "Uten.Padding." + key, "type": "Thickness",
                          "value": ",".join(number(value) for value in values),
                          "sourceRole": symbol, "resolution": evidence,
                          "note": "Omitted EdgeInsets.symmetric axes use the constructor default zero."})

    declaration = tokens.declaration("DesktopLogin.brandSurface")
    match = re.fullmatch(r"Color\.alphaBlend\(\s*theme\.colorScheme\.(\w+)\.withValues\(\s*alpha:\s*dark\s*\?\s*([\d.]+)\s*:\s*([\d.]+)\s*\),\s*theme\.colorScheme\.(\w+)\s*,?\s*\)", masked_code(declaration.expression).strip())
    if not match:
        raise TokenError("Unsupported login brand alphaBlend expression")
    foreground, first_chain = tokens.resolve("LightTheme.colorScheme." + match.group(1), "color")
    background, second_chain = tokens.resolve("LightTheme.colorScheme." + match.group(4), "color")
    alpha = Decimal(match.group(3))
    if not 0 <= alpha <= 1 or background[1:3] != "FF":
        raise TokenError("Unsupported login alpha/background")
    alpha *= Decimal(int(foreground[1:3], 16)) / 255
    channels = [int((Decimal(int(foreground[index:index + 2], 16)) * alpha
                     + Decimal(int(background[index:index + 2], 16)) * (1 - alpha)).quantize(Decimal(1), rounding=ROUND_HALF_UP))
                for index in (3, 5, 7)]
    resources.append({"key": "Uten.LoginBrandSurface", "type": "SolidColorBrush",
                      "value": "#FF" + "".join(f"{value:02X}" for value in channels),
                      "sourceRole": declaration.symbol, "resolution": [declaration.evidence()] + first_chain + second_chain,
                      "computation": "Color.alphaBlend, light branch, floating alpha, round channels to nearest byte (half up)"})
    return resources


def artifacts(root: Path):
    raw = {path: (root / path).read_bytes() for path in source_paths(root)}
    tokens = DartTokens({path: value.decode("utf-8-sig") for path, value in raw.items()})
    resources = build_resources(tokens)
    lines = ["<!-- Generated by sync_design_tokens.py (write mode). Edit owning Dart sources, never this file. -->",
             '<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"',
             '  xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" xmlns:sys="clr-namespace:System;assembly=mscorlib">']
    for resource in resources:
        kind, key, value = resource["type"], resource["key"], resource["value"]
        if kind == "SolidColorBrush":
            lines.append(f'  <SolidColorBrush x:Key="{key}" Color="{value}"/>')
        else:
            tag = "sys:Double" if kind == "Double" else kind
            lines.append(f'  <{tag} x:Key="{key}">{value}</{tag}>')
    lines.extend(["</ResourceDictionary>", ""])
    xaml = "\n".join(lines).encode("utf-8")
    provenance = {
        "schemaVersion": 1, "generator": GENERATOR,
        "generatorSha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "resource": RESOURCE, "resourceSha256": hashlib.sha256(xaml).hexdigest(),
        "scope": "Default Flutter light theme before platform branding or display zoom; WPF device-independent units.",
        "sourceHashFormat": "SHA-256 of exact owning source bytes",
        "sources": [{"path": path, "sha256": hashlib.sha256(value).hexdigest()} for path, value in raw.items()],
        "roleMappings": resources,
    }
    return {RESOURCE: xaml, PROVENANCE: (json.dumps(provenance, ensure_ascii=False, indent=2) + "\n").encode("utf-8")}


def check(root: Path):
    expected = artifacts(root)
    drifted = [path for path, content in expected.items() if not (root / path).is_file() or (root / path).read_bytes() != content]
    if drifted:
        raise TokenError("Design token drift: " + ", ".join(drifted) + ". Review Dart sources, then run --write.")


def write(root: Path):
    expected = artifacts(root)
    for path, content in expected.items():
        target = root / path
        if target.is_symlink() or root not in target.resolve().parents:
            raise TokenError("Generated destination leaves the workspace or is a link: " + path)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--list-sources", action="store_true")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[3])
    args = parser.parse_args()
    try:
        root = args.root.resolve()
        if args.list_sources:
            print(json.dumps(source_paths(root)))
        elif args.write:
            write(root)
            print("Generated WPF design tokens and provenance from owning Dart sources.")
        else:
            check(root)
            print("WPF design tokens and provenance match the owning Dart sources.")
    except (TokenError, OSError, UnicodeError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()
