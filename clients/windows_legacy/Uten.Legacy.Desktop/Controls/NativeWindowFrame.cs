using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace Uten.Legacy.Desktop.Controls
{
    /// <summary>Win7-compatible window clipping, without layered-window software
    /// rendering or Windows 10-only corner APIs. Only this WPF window is changed.</summary>
    internal sealed class NativeWindowFrame
    {
        private IntPtr lastWindow;
        private int lastWidth = -1, lastHeight = -1, lastRadius = -1;
        internal void Update(Window window, bool rounded, double logicalRadius)
        {
            IntPtr handle = new WindowInteropHelper(window).Handle;
            Rect bounds;
            if (handle == IntPtr.Zero || !GetWindowRect(handle, out bounds)) return;
            int width = bounds.Right - bounds.Left, height = bounds.Bottom - bounds.Top;
            var source = PresentationSource.FromVisual(window);
            double scale = source?.CompositionTarget == null ? 1 : source.CompositionTarget.TransformToDevice.M11;
            int radius = rounded ? Math.Max(0, (int)Math.Round(logicalRadius * scale)) : 0;
            if (handle == lastWindow && width == lastWidth && height == lastHeight && radius == lastRadius) return;
            // SetWindowRgn sends size messages synchronously; remember this
            // request first to avoid a reentrant region/resize loop.
            lastWindow = handle; lastWidth = width; lastHeight = height; lastRadius = radius;
            IntPtr region = radius == 0 ? IntPtr.Zero : CreateRoundRectRgn(0, 0, width + 1, height + 1, radius * 2, radius * 2);
            if (radius != 0 && region == IntPtr.Zero) { lastRadius = -1; return; }
            if (SetWindowRgn(handle, region, true) == 0)
            {
                if (region != IntPtr.Zero) DeleteObject(region);
                lastRadius = -1;
            }
            // On success Windows owns and frees the region.
        }
        [StructLayout(LayoutKind.Sequential)] private struct Rect { internal int Left, Top, Right, Bottom; }
        [DllImport("user32.dll", SetLastError = true)] private static extern bool GetWindowRect(IntPtr window, out Rect rect);
        [DllImport("user32.dll", SetLastError = true)] private static extern int SetWindowRgn(IntPtr window, IntPtr region, bool redraw);
        [DllImport("gdi32.dll")] private static extern IntPtr CreateRoundRectRgn(int left, int top, int right, int bottom, int ellipseWidth, int ellipseHeight);
        [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr handle);
    }
}
