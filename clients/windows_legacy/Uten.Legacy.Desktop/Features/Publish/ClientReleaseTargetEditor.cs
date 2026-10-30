using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using Uten.Legacy.Core;

namespace Uten.Legacy.Desktop.Features.Publish
{
    /// <summary>Shared target selector for the publish workbench: the page context panel and the
    /// per-row editor use the same controls and the same platform/family/architecture linkage
    /// rules as the Flutter page.</summary>
    public sealed class ClientReleaseTargetEditor
    {
        private sealed class Choice
        {
            public string Value { get; set; }
            public string Label { get; set; }
            public override string ToString() { return Label; }
        }

        private readonly ComboBox platform = new ComboBox { DisplayMemberPath = "Label", SelectedValuePath = "Value", MinWidth = 160 };
        private readonly ComboBox family = new ComboBox { DisplayMemberPath = "Label", SelectedValuePath = "Value", MinWidth = 180 };
        private readonly ComboBox architecture = new ComboBox { DisplayMemberPath = "Label", SelectedValuePath = "Value", MinWidth = 110 };
        private readonly ComboBox packageKind = new ComboBox { DisplayMemberPath = "Label", SelectedValuePath = "Value", MinWidth = 130 };
        private readonly TextBox version = new TextBox { MinWidth = 110 };
        private readonly TextBox buildNumber = new TextBox { MinWidth = 90 };
        private readonly TextBox storeUrl = new TextBox { MinWidth = 240 };
        private readonly TextBlock storeLabel = new TextBlock { Text = "官方商店链接", VerticalAlignment = VerticalAlignment.Center };
        private readonly StackPanel root;
        private bool binding;

        public ClientReleaseTargetEditor()
        {
            platform.ItemsSource = new[]
            {
                new Choice { Value = "windows", Label = "Windows" },
                new Choice { Value = "android", Label = "Android" },
                new Choice { Value = "ios", Label = "iOS" },
                new Choice { Value = "macos", Label = "macOS" }
            };
            family.ItemsSource = new[]
            {
                new Choice { Value = "flutter", Label = "Windows 10 / 11 常规版" },
                new Choice { Value = "wpf_legacy", Label = "Windows 7 SP1 / 8.1 兼容版" }
            };
            packageKind.ItemsSource = new[]
            {
                new Choice { Value = "installer", Label = "Setup 安装包" },
                new Choice { Value = "update", Label = "更新 ZIP" }
            };
            platform.SelectionChanged += OnPlatformChanged;
            family.SelectionChanged += OnFamilyChanged;
            root = new StackPanel();
            root.Children.Add(Field("系统", platform));
            root.Children.Add(Field("客户端类型", family));
            root.Children.Add(Field("架构", architecture));
            root.Children.Add(Field("包类型", packageKind));
            root.Children.Add(Field("版本", version));
            root.Children.Add(Field("构建号", buildNumber));
            root.Children.Add(StoreField());
        }

        public Panel Root { get { return root; } }

        private Border Field(string label, Control control)
        {
            control.SetResourceReference(FrameworkElement.MinHeightProperty, "Uten.Height.Standard");
            control.Margin = new Thickness(0, 0, 12, 8);
            var text = new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) };
            text.SetResourceReference(TextBlock.ForegroundProperty, "Uten.Muted");
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            row.Children.Add(text);
            row.Children.Add(control);
            var border = new Border { Child = row, Margin = new Thickness(0, 0, 12, 4) };
            return border;
        }

        private Border StoreField()
        {
            storeUrl.SetResourceReference(FrameworkElement.MinHeightProperty, "Uten.Height.Standard");
            var text = storeLabel;
            text.SetResourceReference(TextBlock.ForegroundProperty, "Uten.Muted");
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            row.Children.Add(text);
            row.Children.Add(storeUrl);
            var border = new Border { Child = row, Margin = new Thickness(0, 0, 12, 4), Name = "StoreField" };
            return border;
        }

        public void Bind(ClientReleasePublishMetadata metadata)
        {
            if (metadata == null) return;
            binding = true;
            try
            {
                platform.SelectedValue = metadata.Platform;
                var selectedPlatform = metadata.Platform == "android" || metadata.Platform == "ios" || metadata.Platform == "macos"
                    ? metadata.Platform : "windows";
                family.SelectedValue = metadata.RuntimeFamily ?? "flutter";
                architecture.ItemsSource = ArchitectureChoices(selectedPlatform, metadata.RuntimeFamily ?? "flutter");
                architecture.SelectedValue = metadata.Architecture;
                packageKind.SelectedValue = metadata.PackageKind;
                version.Text = metadata.Version ?? "";
                buildNumber.Text = metadata.BuildNumber ?? "";
                storeUrl.Text = metadata.StoreUrl ?? "";
                SyncVisibility(selectedPlatform, metadata.IsStore);
            }
            finally { binding = false; }
        }

        private void OnPlatformChanged(object sender, SelectionChangedEventArgs e)
        {
            if (binding) return;
            var selected = SelectedPlatform();
            var familyValue = selected == "windows" ? "flutter" : "flutter";
            family.SelectedValue = familyValue;
            architecture.ItemsSource = ArchitectureChoices(selected, familyValue);
            architecture.SelectedValue = selected == "windows" ? "x64" : "universal";
            packageKind.SelectedValue = "update";
            storeUrl.Text = "";
            SyncVisibility(selected, false);
        }

        private void OnFamilyChanged(object sender, SelectionChangedEventArgs e)
        {
            if (binding) return;
            var selected = SelectedPlatform();
            var familyValue = family.SelectedValue as string ?? "flutter";
            var supported = SupportedArchitectures(selected, familyValue);
            var current = architecture.SelectedValue as string;
            architecture.ItemsSource = ArchitectureChoices(selected, familyValue);
            architecture.SelectedValue = supported.Contains(current ?? "") ? current : "x64";
        }

        private string SelectedPlatform()
        {
            var value = platform.SelectedValue as string;
            return value == "android" || value == "ios" || value == "macos" ? value : "windows";
        }

        private void SyncVisibility(string selectedPlatform, bool storeVisible)
        {
            family.Visibility = selectedPlatform == "windows" ? Visibility.Visible : Visibility.Collapsed;
            packageKind.Visibility = selectedPlatform == "windows" ? Visibility.Visible : Visibility.Collapsed;
            var storeField = storeVisible || selectedPlatform == "ios" || selectedPlatform == "macos";
            storeUrl.Visibility = storeField ? Visibility.Visible : Visibility.Collapsed;
            storeLabel.Visibility = storeUrl.Visibility;
        }

        private static IReadOnlyList<string> SupportedArchitectures(string platformName, string familyValue)
        {
            if (platformName == "windows")
                return familyValue == "wpf_legacy" ? new[] { "x64", "x86" } : new[] { "x64", "arm64", "x86" };
            if (platformName == "android") return new[] { "arm64", "armeabi-v7a", "x64", "universal" };
            if (platformName == "ios") return new[] { "arm64", "universal" };
            return new[] { "arm64", "x64", "universal" };
        }

        private static object[] ArchitectureChoices(string platformName, string familyValue)
        {
            var choices = new List<Choice>();
            foreach (var value in SupportedArchitectures(platformName, familyValue))
                choices.Add(new Choice { Value = value, Label = ArchitectureLabel(value) });
            return choices.ToArray();
        }

        public static string ArchitectureLabel(string value)
        {
            switch (value)
            {
                case "x86": return "X86";
                case "x64": return "X64";
                case "arm64": return "ARM64";
                case "armeabi-v7a": return "ARMv7";
                case "universal": return "通用";
                default: return "架构待确认";
            }
        }

        public static string TargetLabel(string platformName, string familyValue, string architectureValue)
        {
            var arch = ArchitectureLabel(architectureValue);
            if (platformName == "windows")
                return (familyValue == "wpf_legacy" ? "Windows 7 SP1 / 8.1 兼容版" : "Windows 10 / 11 常规版") + " · " + arch;
            if (platformName == "android") return "Android · " + arch;
            if (platformName == "ios") return "iOS · " + arch;
            if (platformName == "macos") return "macOS · " + arch;
            return "平台待确认";
        }

        /// <summary>Reads the current selection. The linkage rules keep the combination valid;
        /// the caller still runs the full metadata validation before anything is prepared.</summary>
        public ClientReleasePublishMetadata Read()
        {
            var selectedPlatform = SelectedPlatform();
            var familyValue = selectedPlatform == "windows" ? (string)(family.SelectedValue ?? "flutter") : "flutter";
            var supported = SupportedArchitectures(selectedPlatform, familyValue);
            var arch = architecture.SelectedValue as string;
            if (!supported.Contains(arch ?? "")) arch = supported[0];
            return new ClientReleasePublishMetadata
            {
                Platform = selectedPlatform,
                RuntimeFamily = familyValue,
                Architecture = arch,
                PackageKind = selectedPlatform == "windows" ? (string)(packageKind.SelectedValue ?? "update") : "update",
                Version = version.Text,
                BuildNumber = buildNumber.Text,
                StoreUrl = (storeUrl.Visibility == Visibility.Visible ? storeUrl.Text : null) ?? ""
            };
        }

        public void SetEnabled(bool enabled)
        {
            platform.IsEnabled = enabled;
            family.IsEnabled = enabled;
            architecture.IsEnabled = enabled;
            packageKind.IsEnabled = enabled;
            version.IsEnabled = enabled;
            buildNumber.IsEnabled = enabled;
            storeUrl.IsEnabled = enabled;
        }
    }
}
