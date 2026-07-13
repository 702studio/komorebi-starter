using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;

namespace KomorebiStarter
{
    public static class WindowDiagnostics
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct Point
        {
            public int X;
            public int Y;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct Rect
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct GuiThreadInfo
        {
            public uint Size;
            public uint Flags;
            public IntPtr Active;
            public IntPtr Focus;
            public IntPtr Capture;
            public IntPtr MenuOwner;
            public IntPtr MoveSize;
            public IntPtr Caret;
            public Rect CaretRect;
        }

        public class WindowInfo
        {
            public long Hwnd { get; set; }
            public uint ProcessId { get; set; }
            public string ProcessName { get; set; }
            public string Title { get; set; }
            public string ClassName { get; set; }
            public long OwnerHwnd { get; set; }
            public long RootHwnd { get; set; }
            public long RootOwnerHwnd { get; set; }
            public long LastActivePopupHwnd { get; set; }
            public bool IsVisible { get; set; }
            public bool IsEnabled { get; set; }
            public bool IsMinimized { get; set; }
            public bool IsMaximized { get; set; }
            public bool IsHung { get; set; }
            public bool IsCloaked { get; set; }
            public uint CloakType { get; set; }
            
            // Window rectangle and area metrics
            public int Left { get; set; }
            public int Top { get; set; }
            public int Right { get; set; }
            public int Bottom { get; set; }
            public int Width { get; set; }
            public int Height { get; set; }
            public long Area { get; set; }
            public bool IsOffscreen { get; set; }
            public bool IsZeroArea { get; set; }

            // Styles
            public long Style { get; set; }
            public long ExStyle { get; set; }

            // Decoded Style and Extended Style Boolean Flags
            public bool WsChild => (Style & 0x40000000L) != 0;
            public bool WsDisabled => (Style & 0x08000000L) != 0;
            public bool WsMinimize => (Style & 0x20000000L) != 0;
            public bool WsVisible => (Style & 0x10000000L) != 0;
            public bool WsExToolWindow => (ExStyle & 0x00000080L) != 0;
            public bool WsExNoActivate => (ExStyle & 0x08000000L) != 0;
            public bool WsExLayered => (ExStyle & 0x00080000L) != 0;
            public bool WsExAppWindow => (ExStyle & 0x00040000L) != 0;
            public bool WsExTransparent => (ExStyle & 0x00000020L) != 0;

            public string Error { get; set; }
        }

        public class SystemDiagnostics
        {
            public long ForegroundHwnd { get; set; }
            public long KeyboardFocusHwnd { get; set; }
            public int CursorX { get; set; }
            public int CursorY { get; set; }
            public bool CursorAvailable { get; set; }
            public long MouseUnderHwnd { get; set; }
            public long MouseUnderRootHwnd { get; set; }
        }

        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsWindow(IntPtr window);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsWindowVisible(IntPtr window);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsWindowEnabled(IntPtr window);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsIconic(IntPtr hWnd);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsZoomed(IntPtr hWnd);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsHungAppWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern int GetWindowTextW(IntPtr window, StringBuilder text, int maxCount);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern int GetClassNameW(IntPtr window, StringBuilder className, int maxCount);

        [DllImport("user32.dll")]
        public static extern IntPtr GetAncestor(IntPtr window, uint flags);

        [DllImport("user32.dll")]
        public static extern IntPtr GetWindow(IntPtr window, uint cmd);

        [DllImport("user32.dll")]
        public static extern IntPtr GetLastActivePopup(IntPtr window);

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetCursorPos(out Point point);

        [DllImport("user32.dll")]
        public static extern IntPtr WindowFromPoint(Point point);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetGUIThreadInfo(uint threadId, ref GuiThreadInfo info);

        [DllImport("dwmapi.dll")]
        public static extern int DwmGetWindowAttribute(IntPtr hwnd, uint dwAttribute, out uint pvAttribute, uint cbAttribute);

        [DllImport("user32.dll")]
        public static extern int GetSystemMetrics(int nIndex);

        [DllImport("user32.dll", EntryPoint = "GetWindowLong")]
        private static extern IntPtr GetWindowLongPtr32(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")]
        private static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetWindowRect(IntPtr hWnd, out Rect lpRect);

        public static IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex)
        {
            if (IntPtr.Size == 8)
                return GetWindowLongPtr64(hWnd, nIndex);
            else
                return GetWindowLongPtr32(hWnd, nIndex);
        }

        public static string ReadWindowText(IntPtr window)
        {
            var text = new StringBuilder(1024);
            GetWindowTextW(window, text, text.Capacity);
            return text.ToString();
        }

        public static string ReadWindowClass(IntPtr window)
        {
            var className = new StringBuilder(512);
            GetClassNameW(window, className, className.Capacity);
            return className.ToString();
        }

        public static bool IsCloaked(IntPtr hwnd, out uint cloakType)
        {
            uint cloaked = 0;
            // DWMWA_CLOAKED = 14
            int hr = DwmGetWindowAttribute(hwnd, 14, out cloaked, sizeof(uint));
            cloakType = cloaked;
            return hr == 0 && cloaked != 0;
        }

        public static IntPtr GetKeyboardFocusWindow()
        {
            var foreground = GetForegroundWindow();
            if (foreground == IntPtr.Zero)
            {
                return IntPtr.Zero;
            }

            uint processId;
            var threadId = GetWindowThreadProcessId(foreground, out processId);
            var info = new GuiThreadInfo();
            info.Size = (uint)Marshal.SizeOf(typeof(GuiThreadInfo));
            // Read GUI-thread info containing focus child window of target window
            return GetGUIThreadInfo(threadId, ref info) ? info.Focus : IntPtr.Zero;
        }

        public static SystemDiagnostics CollectSystemDiagnostics()
        {
            var diag = new SystemDiagnostics();
            try
            {
                diag.ForegroundHwnd = GetForegroundWindow().ToInt64();
            }
            catch {}

            try
            {
                var keyboardHwnd = GetKeyboardFocusWindow();
                diag.KeyboardFocusHwnd = keyboardHwnd.ToInt64();
            }
            catch {}

            try
            {
                Point pt;
                if (GetCursorPos(out pt))
                {
                    diag.CursorAvailable = true;
                    diag.CursorX = pt.X;
                    diag.CursorY = pt.Y;
                    var mouseHwnd = WindowFromPoint(pt);
                    diag.MouseUnderHwnd = mouseHwnd.ToInt64();
                    diag.MouseUnderRootHwnd = GetAncestor(mouseHwnd, 2).ToInt64(); // GA_ROOT = 2
                }
            }
            catch {}

            return diag;
        }

        public static List<WindowInfo> CollectWindows()
        {
            var list = new List<WindowInfo>();

            // Retrieve virtual screen coordinates for offscreen check
            int virtualLeft = GetSystemMetrics(76); // SM_XVIRTUALSCREEN
            int virtualTop = GetSystemMetrics(77); // SM_YVIRTUALSCREEN
            int virtualWidth = GetSystemMetrics(78); // SM_CXVIRTUALSCREEN
            int virtualHeight = GetSystemMetrics(79); // SM_CYVIRTUALSCREEN
            int virtualRight = virtualLeft + virtualWidth;
            int virtualBottom = virtualTop + virtualHeight;

            EnumWindows((hwnd, lParam) =>
            {
                var info = new WindowInfo { Hwnd = hwnd.ToInt64() };
                try
                {
                    if (!IsWindow(hwnd))
                    {
                        info.Error = "Not a valid window";
                        list.Add(info);
                        return true;
                    }

                    uint pid;
                    GetWindowThreadProcessId(hwnd, out pid);
                    info.ProcessId = pid;

                    try
                    {
                        using (var proc = System.Diagnostics.Process.GetProcessById((int)pid))
                        {
                            info.ProcessName = proc.ProcessName;
                        }
                    }
                    catch (Exception)
                    {
                        info.ProcessName = null;
                    }

                    info.Title = ReadWindowText(hwnd);
                    info.ClassName = ReadWindowClass(hwnd);
                    info.OwnerHwnd = GetWindow(hwnd, 4).ToInt64(); // GW_OWNER = 4
                    info.RootHwnd = GetAncestor(hwnd, 2).ToInt64(); // GA_ROOT = 2
                    info.RootOwnerHwnd = GetAncestor(hwnd, 3).ToInt64(); // GA_ROOTOWNER = 3
                    info.LastActivePopupHwnd = GetLastActivePopup(hwnd).ToInt64();
                    info.IsVisible = IsWindowVisible(hwnd);
                    info.IsEnabled = IsWindowEnabled(hwnd);
                    info.IsMinimized = IsIconic(hwnd);
                    info.IsMaximized = IsZoomed(hwnd);
                    info.IsHung = IsHungAppWindow(hwnd);

                    uint cloakType;
                    info.IsCloaked = IsCloaked(hwnd, out cloakType);
                    info.CloakType = cloakType;

                    Rect rect;
                    if (GetWindowRect(hwnd, out rect))
                    {
                        info.Left = rect.Left;
                        info.Top = rect.Top;
                        info.Right = rect.Right;
                        info.Bottom = rect.Bottom;
                        info.Width = rect.Right - rect.Left;
                        info.Height = rect.Bottom - rect.Top;
                        info.Area = (long)info.Width * info.Height;

                        // Check if window coordinates are completely outside the virtual desktop bounds
                        info.IsOffscreen = (rect.Right <= virtualLeft || 
                                            rect.Left >= virtualRight || 
                                            rect.Bottom <= virtualTop || 
                                            rect.Top >= virtualBottom);
                        info.IsZeroArea = (info.Width <= 0 || info.Height <= 0);
                    }
                    else
                    {
                        info.IsOffscreen = true;
                        info.IsZeroArea = true;
                    }

                    info.Style = GetWindowLongPtr(hwnd, -16).ToInt64(); // GWL_STYLE = -16
                    info.ExStyle = GetWindowLongPtr(hwnd, -20).ToInt64(); // GWL_EXSTYLE = -20
                }
                catch (Exception ex)
                {
                    info.Error = ex.Message;
                }

                list.Add(info);
                return true;
            }, IntPtr.Zero);

            return list;
        }
    }
}
