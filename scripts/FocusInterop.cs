using System;
using System.Runtime.InteropServices;
using System.Text;

namespace KomorebiStarter
{
    public static class NativeFocus
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

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        public static extern IntPtr GetAncestor(IntPtr window, uint flags);

        [DllImport("user32.dll")]
        public static extern IntPtr GetLastActivePopup(IntPtr window);

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
        public static extern bool IsIconic(IntPtr window);

        [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
        private static extern int GetWindowLongW32(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
        private static extern IntPtr GetWindowLongPtrW64(IntPtr hWnd, int nIndex);

        public static IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex)
        {
            if (IntPtr.Size == 8)
            {
                return GetWindowLongPtrW64(hWnd, nIndex);
            }
            else
            {
                return new IntPtr(GetWindowLongW32(hWnd, nIndex));
            }
        }

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetForegroundWindow(IntPtr window);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetCursorPos(out Point point);

        [DllImport("user32.dll")]
        public static extern IntPtr WindowFromPoint(Point point);

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowText(IntPtr window, StringBuilder text, int maxCount);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr window, StringBuilder className, int maxCount);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetGUIThreadInfo(uint threadId, ref GuiThreadInfo info);

        public static uint GetWindowProcessId(IntPtr window)
        {
            uint processId;
            GetWindowThreadProcessId(window, out processId);
            return processId;
        }

        public static string ReadWindowText(IntPtr window)
        {
            var text = new StringBuilder(1024);
            GetWindowText(window, text, text.Capacity);
            return text.ToString();
        }

        public static string ReadWindowClass(IntPtr window)
        {
            var className = new StringBuilder(512);
            GetClassName(window, className, className.Capacity);
            return className.ToString();
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
            return GetGUIThreadInfo(threadId, ref info) ? info.Focus : IntPtr.Zero;
        }
    }
}
