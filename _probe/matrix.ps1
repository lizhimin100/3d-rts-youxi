param([switch]$Detach)
$ErrorActionPreference = 'Stop'
$src = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class P2 {
  [StructLayout(LayoutKind.Sequential)] public struct SA { public int nLength; public IntPtr sd; public int inherit; }
  [StructLayout(LayoutKind.Sequential)] public struct SI {
    public int cb; public IntPtr r1,desktop,title;
    public int x,y,xs,ys,xc,yc,fill,flags; public short show,cb2;
    public IntPtr r2,hIn,hOut,hErr; }
  [StructLayout(LayoutKind.Sequential)] public struct PI { public IntPtr hP,hT; public int pid,tid; }
  [StructLayout(LayoutKind.Sequential)] public struct SIA { public IntPtr Sid; public uint Attr; }

  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll", SetLastError=true)] public static extern void SetLastError(uint e);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetExitCodeProcess(IntPtr h, out uint c);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GetConsoleWindow();
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeConsole();
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr CreateFileW(string n, uint a, uint s, ref SA sa, uint d, uint f, IntPtr t);
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool OpenProcessToken(IntPtr p, uint a, out IntPtr t);
  [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool CreateRestrictedToken(IntPtr t, uint f, uint nd, IntPtr d, uint nl, IntPtr l, uint nr, SIA[] r, out IntPtr nt);
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool SetTokenInformation(IntPtr t, int c, IntPtr i, int l);
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool GetTokenInformation(IntPtr t, int c, IntPtr i, int l, out int need);
  [DllImport("advapi32.dll", SetLastError=true)] public static extern int GetLengthSid(IntPtr s);
  [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool ConvertStringSidToSidW(string s, out IntPtr sid);
  [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool ConvertSidToStringSidW(IntPtr sid, out IntPtr str);
  [DllImport("kernel32.dll")] public static extern IntPtr LocalFree(IntPtr p);
  [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool CreateProcessAsUserW(IntPtr tok, string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inh, uint fl, IntPtr env, string cwd, ref SI si, out PI pi);
  [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool CreateProcessWithTokenW(IntPtr tok, uint logon, string app, StringBuilder cmd, uint fl, IntPtr env, string cwd, ref SI si, out PI pi);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inh, uint fl, IntPtr env, string cwd, ref SI si, out PI pi);

  public static string SidStr(IntPtr sid) {
    IntPtr s; if(!ConvertSidToStringSidW(sid, out s)) return "?";
    string r = Marshal.PtrToStringUni(s); LocalFree(s); return r;
  }

  // returns token handle; sids comma list; low 0/1; restrict 0/1
  public static IntPtr Build(int restrict, int low, string sids, uint tflags, out string note) {
    note = "";
    IntPtr tok; if (!OpenProcessToken(GetCurrentProcess(), 0xF01FF, out tok)) throw new Exception("OpenProcessToken err=" + Marshal.GetLastWin32Error());
    if (restrict == 1) {
      int need; GetTokenInformation(tok, 2, IntPtr.Zero, 0, out need);
      if (need <= 0) throw new Exception("TokenGroups size query need=" + need); IntPtr g = Marshal.AllocHGlobal(need); if (!GetTokenInformation(tok, 2, g, need, out need)) throw new Exception("TokenGroups read err=" + Marshal.GetLastWin32Error());
      uint count = (uint)Marshal.ReadInt32(g); IntPtr found = IntPtr.Zero;
      for (uint k = 0; k < count; k++) {
        IntPtr e = (IntPtr)((long)g + 8 + k * 16);
        if (((uint)Marshal.ReadInt32(e, 8) & 0xC0000000) == 0xC0000000) { found = Marshal.ReadIntPtr(e); break; }
      }
      var arr = new System.Collections.Generic.List<SIA>();
      foreach (string name in sids.Split(',')) {
        IntPtr sid;
        if (name == "logon") {
          IntPtr str; ConvertSidToStringSidW(found, out str);
          ConvertStringSidToSidW(Marshal.PtrToStringUni(str), out sid);
        } else if (name == "everyone") ConvertStringSidToSidW("S-1-1-0", out sid);
        else if (name == "write") ConvertStringSidToSidW("S-1-4-1234-5678-9012-3456", out sid);
        else ConvertStringSidToSidW(name, out sid);
        arr.Add(new SIA { Sid = sid, Attr = 0 });
      }
      IntPtr nt;
      if (!CreateRestrictedToken(tok, tflags, 0, IntPtr.Zero, 0, IntPtr.Zero, (uint)arr.Count, arr.ToArray(), out nt))
        throw new Exception("CreateRestrictedToken err=" + Marshal.GetLastWin32Error() + " tok=" + tok + " n=" + arr.Count);
      CloseHandle(tok); tok = nt;
      note += "restricted[" + string.Join(",", arr.ConvertAll(x => SidStr(x.Sid)).ToArray()) + "] ";
    }
    if (low == 1) {
      IntPtr ls; ConvertStringSidToSidW("S-1-16-4096", out ls);
      int len = 16 + GetLengthSid(ls);
      IntPtr info = Marshal.AllocHGlobal(len);
      Marshal.StructureToPtr(new SIA { Sid = ls, Attr = 0x20 }, info, false);
      if (!SetTokenInformation(tok, 25, info, len))
        throw new Exception("SetTokenInformation(TIL) " + Marshal.GetLastWin32Error());
      note += "lowIL ";
    }
    return tok;
  }

  public static string Run(IntPtr tok, int withToken, string app, string cmdline, string cwd, uint flags, string outFile) {
    var sa = new SA { nLength = Marshal.SizeOf(typeof(SA)), inherit = 1 };
    IntPtr hOut = CreateFileW(outFile, 0x40000000, 3, ref sa, 2, 0, IntPtr.Zero);
    IntPtr hIn  = CreateFileW("NUL", 0x80000000, 3, ref sa, 3, 0, IntPtr.Zero);
    var si = new SI { cb = Marshal.SizeOf(typeof(SI)), flags = 0x100, hIn = hIn, hOut = hOut, hErr = hOut };
    var pi = new PI(); var sb = new StringBuilder(cmdline);
    SetLastError(0);
    bool ok;
    if (tok == IntPtr.Zero) ok = CreateProcessW(app, sb, IntPtr.Zero, IntPtr.Zero, true, flags, IntPtr.Zero, cwd, ref si, out pi);
    else if (withToken == 1) ok = CreateProcessWithTokenW(tok, 0, app, sb, flags, IntPtr.Zero, cwd, ref si, out pi);
    else ok = CreateProcessAsUserW(tok, app, sb, IntPtr.Zero, IntPtr.Zero, true, flags, IntPtr.Zero, cwd, ref si, out pi);
    int err = Marshal.GetLastWin32Error();
    CloseHandle(hOut); CloseHandle(hIn);
    if (!ok) return "SPAWNFAIL err=" + err;
    WaitForSingleObject(pi.hP, 30000);
    uint code; GetExitCodeProcess(pi.hP, out code);
    CloseHandle(pi.hP); CloseHandle(pi.hT);
    string text = ""; try { text = System.IO.File.ReadAllText(outFile); } catch {}
    text = text.Replace("\r", "").Replace("\n", "\\n");
    return string.Format("exit=0x{0:X8} out=[{1}]", code, text);
  }
}
'@
Add-Type -TypeDefinition $src -Language CSharp

$D = 'E:\自定义游戏\简易rts\_probe'
$PW  = 'C:\Program Files\PowerShell\7\pwsh.exe'
$PS5 = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$CMD = 'C:\Windows\System32\cmd.exe'

"console_before=$([P2]::GetConsoleWindow() -ne [IntPtr]::Zero) detach=$Detach"
if ($Detach) { [void][P2]::FreeConsole(); "console_after=$([P2]::GetConsoleWindow() -ne [IntPtr]::Zero)" }

function Case($name, $tok, $app, $args_, $flags, $withToken, $note) {
  $of = Join-Path $D ("o_" + ($name -replace '[^A-Za-z0-9]','_') + ".txt")
  if (Test-Path $of) { Remove-Item $of -Force }
  $cmd = "`"$app`" $args_"
  $r = [P2]::Run($tok, $withToken, $app, $cmd, $D, [uint32]$flags, $of)
  "{0,-38} {1,-46} flags=0x{2:X8} {3}" -f $name, $r, $flags, $note
}

$pwArgs = '-NoLogo -NoProfile -NonInteractive -Command "Write-Output hi"'
$cmdArgs = '/c "echo hi"'
$tNone = [IntPtr]::Zero
$n1=""; $tRL  = [P2]::Build(1,1,'logon,everyone,write',13,[ref]$n1)
$n1=""; $tR   = [P2]::Build(1,0,'logon,everyone,write',13,[ref]$n1)
$n1=""; $tL   = [P2]::Build(0,1,'',13,[ref]$n1)
$n2=""; $tRE  = [P2]::Build(1,0,'everyone',13,[ref]$n2)
$n3=""; $tRL2 = [P2]::Build(1,1,'logon,everyone',13,[ref]$n3)

"--- baseline ---"
Case 'none/pwsh'      $tNone $PW  $pwArgs 0 0 ''
Case 'none/cmd'       $tNone $CMD $cmdArgs 0 0 ''
"--- restricted+low ---"
Case 'rl/pwsh'        $tRL $PW  $pwArgs 0 0 ''
Case 'rl/cmd'         $tRL $CMD $cmdArgs 0 0 ''
Case 'rl/pwsh-NOWIN'  $tRL $PW  $pwArgs 0x08000000 0 ''
Case 'rl/pwsh-NEWCON' $tRL $PW  $pwArgs 0x00000010 0 ''
Case 'rl/pwsh-DETACH' $tRL $PW  $pwArgs 0x00000008 0 ''
"--- token variants ---"
Case 'r-only/pwsh'    $tR  $PW  $pwArgs 0 0 ''
Case 'low-only/pwsh'  $tL  $PW  $pwArgs 0 0 ''
Case 'r-everyone/pwsh' $tRE $PW $pwArgs 0 0 ''
Case 'rl-noWriteSid/pwsh' $tRL2 $PW $pwArgs 0 0 ''
Case 'rl/pwsh-WithToken' $tRL $PW $pwArgs 0 1 ''
"--- subsystem test (restricted+low) ---"
Case 'rl/HelloC-console' $tRL (Join-Path $D 'HelloC.exe') ("`"" + (Join-Path $D 'h1.txt') + "`"") 0 0 ''
Case 'rl/HelloG-gui'     $tRL (Join-Path $D 'HelloG.exe') ("`"" + (Join-Path $D 'h2.txt') + "`"") 0 0 ''
"--- powershell 5.1 ---"
Case 'rl/ps5'         $tRL $PS5 '-NoLogo -NoProfile -NonInteractive -Command "Write-Output hi"' 0 0 ''



