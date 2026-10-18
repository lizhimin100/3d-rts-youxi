$ErrorActionPreference='Stop'
$src = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class T {
  [StructLayout(LayoutKind.Sequential)] public struct SA { public int nLength; public IntPtr sd; public int inherit; }
  [StructLayout(LayoutKind.Sequential)] public struct SI {
    public int cb; public IntPtr r1; public IntPtr desktop; public IntPtr title;
    public int x,y,xs,ys,xc,yc,fill,flags; public short show; public short cb2;
    public IntPtr r2; public IntPtr hIn,hOut,hErr; }
  [StructLayout(LayoutKind.Sequential)] public struct PI { public IntPtr hP,hT; public int pid,tid; }
  [StructLayout(LayoutKind.Sequential)] public struct SIA { public IntPtr Sid; public uint Attr; }
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll", SetLastError=true)] public static extern void SetLastError(uint e);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetExitCodeProcess(IntPtr h, out uint c);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GetConsoleWindow();
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeConsole();
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool OpenProcessToken(IntPtr p, uint a, out IntPtr t);
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool CreateRestrictedToken(IntPtr t, uint f, uint nd, IntPtr d, uint nl, IntPtr l, uint nr, SIA[] r, out IntPtr nt);
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool SetTokenInformation(IntPtr t, int c, IntPtr i, int l);
  [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool ConvertStringSidToSidW(string s, out IntPtr sid);
  [DllImport("advapi32.dll", SetLastError=true)] public static extern int GetLengthSid(IntPtr s);
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool CreateProcessAsUserW(IntPtr tok, string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inh, uint fl, IntPtr env, string cwd, ref SI si, out PI pi);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inh, uint fl, IntPtr env, string cwd, ref SI si, out PI pi);
  public static string LastErr() { return Marshal.GetLastWin32Error().ToString(); }
  public static bool Spawn(IntPtr tok, string app, string cmdline, string cwd, uint flags, out string msg) {
    var si = new SI(); si.cb = Marshal.SizeOf(typeof(SI));
    var pi = new PI(); var cmd = new StringBuilder(cmdline);
    SetLastError(0);
    bool ok;
    if (tok == IntPtr.Zero) ok = CreateProcessW(app, cmd, IntPtr.Zero, IntPtr.Zero, false, flags, IntPtr.Zero, cwd, ref si, out pi);
    else ok = CreateProcessAsUserW(tok, app, cmd, IntPtr.Zero, IntPtr.Zero, false, flags, IntPtr.Zero, cwd, ref si, out pi);
    int err = Marshal.GetLastWin32Error();
    if (!ok) { msg = "FAIL err=" + err; return false; }
    WaitForSingleObject(pi.hP, 0xFFFFFFFF);
    uint code; GetExitCodeProcess(pi.hP, out code);
    CloseHandle(pi.hP); CloseHandle(pi.hT);
    msg = "OK exit=0x" + code.ToString("X8") + " pid=" + pi.pid;
    return true;
  }
}
'@
Add-Type -TypeDefinition $src -Language CSharp

$probe = 'E:\自定义游戏\简易rts\_probe'
$pw = 'C:\Program Files\PowerShell\7\pwsh.exe'
"console=" + ([T]::GetConsoleWindow() -ne [IntPtr]::Zero)

# own token, unmodified
$tok=[IntPtr]::Zero
[void][T]::OpenProcessToken([T]::GetCurrentProcess(), 0xF01FF, [ref]$tok)
$m=''; $r=[T]::Spawn($tok, $null, "`"$pw`" -NoLogo -NoProfile -NonInteractive -Command `"Write-Output hi > $probe\b1.txt`"", 'C:\Windows', 0, [ref]$m)
"unmodified-token: $m"
[void][T]::CloseHandle($tok)

# no token baseline
$r=[T]::Spawn([IntPtr]::Zero, $null, "`"$pw`" -NoLogo -NoProfile -NonInteractive -Command `"Write-Output hi > $probe\b2.txt`"", 'C:\Windows', 0, [ref]$m)
"no-token: $m"