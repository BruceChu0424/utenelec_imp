using System;
using System.Windows;
using System.Windows.Controls;

namespace Uten.Legacy.Desktop.Controls
{
    /// <summary>Entry pages keep touch/wheel scrolling while hiding the rail on
    /// narrow windows. Document and editor viewers opt in separately, so their
    /// existing rails and keyboard behavior are unchanged.</summary>
    public static class UtenEntryPageScrollBehavior
    {
        public static readonly DependencyProperty EnabledProperty = DependencyProperty.RegisterAttached(
            "Enabled", typeof(bool), typeof(UtenEntryPageScrollBehavior), new PropertyMetadata(false, OnEnabledChanged));
        private static readonly DependencyProperty SubscriptionProperty = DependencyProperty.RegisterAttached(
            "Subscription", typeof(Subscription), typeof(UtenEntryPageScrollBehavior));

        public static void SetEnabled(ScrollViewer viewer, bool value) { viewer.SetValue(EnabledProperty, value); }
        public static bool GetEnabled(ScrollViewer viewer) { return (bool)viewer.GetValue(EnabledProperty); }

        private static void OnEnabledChanged(DependencyObject target, DependencyPropertyChangedEventArgs args)
        {
            var viewer = target as ScrollViewer;
            if (viewer == null) throw new ArgumentException("Entry-page scrolling requires a ScrollViewer.");
            var previous = viewer.GetValue(SubscriptionProperty) as Subscription;
            previous?.Dispose();
            viewer.SetValue(SubscriptionProperty, (bool)args.NewValue ? new Subscription(viewer) : null);
        }

        private sealed class Subscription : IDisposable
        {
            private readonly ScrollViewer viewer;
            private FrameworkElement windowContent;
            private readonly ScrollBarVisibility originalVisibility;
            private readonly PanningMode originalPanning;

            internal Subscription(ScrollViewer viewer)
            {
                this.viewer = viewer;
                originalVisibility = viewer.VerticalScrollBarVisibility;
                originalPanning = viewer.PanningMode;
                viewer.PanningMode = PanningMode.VerticalOnly;
                viewer.Loaded += OnLoaded;
                viewer.Unloaded += OnUnloaded;
                if (viewer.IsLoaded) Attach();
            }
            private void OnLoaded(object sender, RoutedEventArgs args) { Attach(); }
            private void OnUnloaded(object sender, RoutedEventArgs args) { Detach(); }
            private void Attach()
            {
                Detach();
                windowContent = Window.GetWindow(viewer)?.Content as FrameworkElement ?? viewer;
                windowContent.SizeChanged += OnSizeChanged;
                Update();
            }
            private void OnSizeChanged(object sender, SizeChangedEventArgs args) { Update(); }
            private void Update()
            {
                double threshold = (double)viewer.FindResource("Uten.Breakpoint.DesktopStart");
                viewer.VerticalScrollBarVisibility = windowContent.ActualWidth < threshold
                    ? ScrollBarVisibility.Hidden : originalVisibility;
            }
            private void Detach()
            {
                if (windowContent != null) windowContent.SizeChanged -= OnSizeChanged;
                windowContent = null;
            }
            public void Dispose()
            {
                Detach();
                viewer.Loaded -= OnLoaded;
                viewer.Unloaded -= OnUnloaded;
                viewer.VerticalScrollBarVisibility = originalVisibility;
                viewer.PanningMode = originalPanning;
            }
        }
    }
}
