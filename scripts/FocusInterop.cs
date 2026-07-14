using System;
using System.Runtime.InteropServices;
using System.Text;

namespace KomorebiStarter
{
    public static class NativeProcess
    {
        private const uint GenericRead = 0x80000000;
        private const uint FileAppendData = 0x00000004;
        private const uint FileShareRead = 0x00000001;
        private const uint FileShareWrite = 0x00000002;
        private const uint OpenAlways = 4;
        private const uint OpenExisting = 3;
        private const uint FileAttributeNormal = 0x00000080;
        private const uint StartfUseStdHandles = 0x00000100;
        private const uint CreateNoWindow = 0x08000000;
        private const uint ExtendedStartupInfoPresent = 0x00080000;
        private const int ProcThreadAttributeHandleList = 0x00020002;

        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes
        {
            public int Length;
            public IntPtr SecurityDescriptor;

            [MarshalAs(UnmanagedType.Bool)]
            public bool InheritHandle;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct StartupInfo
        {
            public int Size;
            public string Reserved;
            public string Desktop;
            public string Title;
            public int X;
            public int Y;
            public int XSize;
            public int YSize;
            public int XCountChars;
            public int YCountChars;
            public int FillAttribute;
            public int Flags;
            public short ShowWindow;
            public short Reserved2Size;
            public IntPtr Reserved2;
            public IntPtr StandardInput;
            public IntPtr StandardOutput;
            public IntPtr StandardError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInformation
        {
            public IntPtr Process;
            public IntPtr Thread;
            public int ProcessId;
            public int ThreadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct StartupInfoEx
        {
            public StartupInfo StartupInfo;
            public IntPtr AttributeList;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateFileW(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            ref SecurityAttributes securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProcessW(
            string applicationName,
            StringBuilder commandLine,
            IntPtr processAttributes,
            IntPtr threadAttributes,
            [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
            uint creationFlags,
            IntPtr environment,
            string currentDirectory,
            ref StartupInfoEx startupInfo,
            out ProcessInformation processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool InitializeProcThreadAttributeList(
            IntPtr attributeList,
            int attributeCount,
            int flags,
            ref IntPtr size);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UpdateProcThreadAttribute(
            IntPtr attributeList,
            uint flags,
            IntPtr attribute,
            IntPtr value,
            IntPtr size,
            IntPtr previousValue,
            IntPtr returnSize);

        [DllImport("kernel32.dll")]
        private static extern void DeleteProcThreadAttributeList(IntPtr attributeList);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        public static int StartDetached(
            string applicationPath,
            string arguments,
            string workingDirectory,
            string standardOutputPath,
            string standardErrorPath)
        {
            var inheritable = new SecurityAttributes
            {
                Length = Marshal.SizeOf(typeof(SecurityAttributes)),
                SecurityDescriptor = IntPtr.Zero,
                InheritHandle = true
            };

            var standardInput = CreateFileW(
                "NUL",
                GenericRead,
                FileShareRead | FileShareWrite,
                ref inheritable,
                OpenExisting,
                FileAttributeNormal,
                IntPtr.Zero);
            var standardOutput = CreateFileW(
                standardOutputPath,
                FileAppendData,
                FileShareRead | FileShareWrite,
                ref inheritable,
                OpenAlways,
                FileAttributeNormal,
                IntPtr.Zero);
            var standardError = CreateFileW(
                standardErrorPath,
                FileAppendData,
                FileShareRead | FileShareWrite,
                ref inheritable,
                OpenAlways,
                FileAttributeNormal,
                IntPtr.Zero);

            var invalidHandle = new IntPtr(-1);
            if (standardInput == invalidHandle || standardOutput == invalidHandle || standardError == invalidHandle)
            {
                var error = Marshal.GetLastWin32Error();
                CloseIfValid(standardInput, invalidHandle);
                CloseIfValid(standardOutput, invalidHandle);
                CloseIfValid(standardError, invalidHandle);
                throw new InvalidOperationException("Unable to open detached process streams. Win32 error: " + error);
            }

            try
            {
                var attributeListSize = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attributeListSize);
                var attributeList = Marshal.AllocHGlobal(attributeListSize);
                var inheritedHandles = Marshal.AllocHGlobal(IntPtr.Size * 3);
                var attributeListInitialized = false;

                try
                {
                    if (!InitializeProcThreadAttributeList(attributeList, 1, 0, ref attributeListSize))
                    {
                        throw new InvalidOperationException(
                            "Unable to initialize the detached process handle list. Win32 error: " + Marshal.GetLastWin32Error());
                    }
                    attributeListInitialized = true;

                    Marshal.WriteIntPtr(inheritedHandles, 0, standardInput);
                    Marshal.WriteIntPtr(inheritedHandles, IntPtr.Size, standardOutput);
                    Marshal.WriteIntPtr(inheritedHandles, IntPtr.Size * 2, standardError);
                    if (!UpdateProcThreadAttribute(
                        attributeList,
                        0,
                        new IntPtr(ProcThreadAttributeHandleList),
                        inheritedHandles,
                        new IntPtr(IntPtr.Size * 3),
                        IntPtr.Zero,
                        IntPtr.Zero))
                    {
                        throw new InvalidOperationException(
                            "Unable to restrict detached process handle inheritance. Win32 error: " + Marshal.GetLastWin32Error());
                    }

                    var startupInfo = new StartupInfoEx
                    {
                        StartupInfo = new StartupInfo
                        {
                            Size = Marshal.SizeOf(typeof(StartupInfoEx)),
                            Flags = (int)StartfUseStdHandles,
                            StandardInput = standardInput,
                            StandardOutput = standardOutput,
                            StandardError = standardError
                        },
                        AttributeList = attributeList
                    };
                    var commandLine = new StringBuilder(
                        "\"" + applicationPath + "\"" +
                        (string.IsNullOrWhiteSpace(arguments) ? string.Empty : " " + arguments));

                    ProcessInformation processInformation;
                    if (!CreateProcessW(
                        applicationPath,
                        commandLine,
                        IntPtr.Zero,
                        IntPtr.Zero,
                        true,
                        CreateNoWindow | ExtendedStartupInfoPresent,
                        IntPtr.Zero,
                        workingDirectory,
                        ref startupInfo,
                        out processInformation))
                    {
                        throw new InvalidOperationException(
                            "Unable to start detached process. Win32 error: " + Marshal.GetLastWin32Error());
                    }

                    try
                    {
                        return processInformation.ProcessId;
                    }
                    finally
                    {
                        CloseHandle(processInformation.Thread);
                        CloseHandle(processInformation.Process);
                    }
                }
                finally
                {
                    if (attributeListInitialized)
                    {
                        DeleteProcThreadAttributeList(attributeList);
                    }
                    Marshal.FreeHGlobal(inheritedHandles);
                    Marshal.FreeHGlobal(attributeList);
                }
            }
            finally
            {
                CloseHandle(standardInput);
                CloseHandle(standardOutput);
                CloseHandle(standardError);
            }
        }

        private static void CloseIfValid(IntPtr handle, IntPtr invalidHandle)
        {
            if (handle != IntPtr.Zero && handle != invalidHandle)
            {
                CloseHandle(handle);
            }
        }
    }

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

        [DllImport("user32.dll", EntryPoint = "SetWindowLongW", SetLastError = true)]
        private static extern int SetWindowLongW32(IntPtr hWnd, int nIndex, int value);

        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)]
        private static extern IntPtr SetWindowLongPtrW64(IntPtr hWnd, int nIndex, IntPtr value);

        [DllImport("kernel32.dll", EntryPoint = "SetLastError")]
        private static extern void ClearLastError(uint errorCode);

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

        public static bool AddExtendedWindowStyle(
            IntPtr hWnd,
            long styleMask,
            out long before,
            out long after,
            out int win32Error)
        {
            before = GetWindowLongPtr(hWnd, -20).ToInt64();
            var desired = before | styleMask;
            after = before;
            win32Error = 0;

            if (desired == before)
            {
                return true;
            }

            ClearLastError(0);
            IntPtr previous;
            if (IntPtr.Size == 8)
            {
                previous = SetWindowLongPtrW64(hWnd, -20, new IntPtr(desired));
            }
            else
            {
                previous = new IntPtr(SetWindowLongW32(hWnd, -20, unchecked((int)desired)));
            }

            win32Error = Marshal.GetLastWin32Error();
            if (previous == IntPtr.Zero && win32Error != 0)
            {
                return false;
            }

            after = GetWindowLongPtr(hWnd, -20).ToInt64();
            return (after & styleMask) == styleMask;
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
