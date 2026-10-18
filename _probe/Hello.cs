using System;
using System.IO;
using System.Runtime.InteropServices;

class Hello
{
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
    [DllImport("kernel32.dll")] static extern bool AllocConsole();
    static void Main(string[] args)
    {
        string path = args.Length > 0 ? args[0] : "hello.txt";
        string cw = GetConsoleWindow() == IntPtr.Zero ? "none" : "0x" + GetConsoleWindow().ToInt64().ToString("X");
        File.WriteAllText(path, "SUBSYS-OK console=" + cw + " pid=" + System.Diagnostics.Process.GetCurrentProcess().Id);
    }
}
