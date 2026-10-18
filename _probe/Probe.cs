using System;
using System.Text;
using System.Runtime.InteropServices;

class Probe
{
    [StructLayout(LayoutKind.Sequential)] struct SA { public int nLength; public IntPtr sd; public int inherit; }
    [StructLayout(LayoutKind.Sequential)] struct SI {
        public int cb; public IntPtr r1; public IntPtr desktop; public IntPtr title;
        public int x,y,xs,ys,xc,yc,fill,flags; public short show; public short cb2;
        public IntPtr r2; public IntPtr hIn,hOut,hErr;
    }
    [StructLayout(LayoutKind.Sequential)] struct PI { public IntPtr hP,hT; public int pid,tid; }
    [StructLayout(LayoutKind.Sequential)] struct SIA { public IntPtr Sid; public uint Attr; }

    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr GetConsoleWindow();
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool AllocConsole();
    [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, ref SA sa, uint disp, uint flags, IntPtr tmpl);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr p, uint access, out IntPtr tok);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool CreateRestrictedToken(IntPtr tok, uint flags, uint nDisable, IntPtr disable,
        uint nDel, IntPtr del, uint nRestrict, SIA[] restrict, out IntPtr newTok);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool SetTokenInformation(IntPtr tok, int cls, IntPtr info, int len);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool GetTokenInformation(IntPtr tok, int cls, IntPtr info, int len, out int need);
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern bool ConvertStringSidToSidW(string s, out IntPtr sid);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool CreateProcessAsUserW(IntPtr tok, string app, StringBuilder cmd, IntPtr pa, IntPtr ta,
        bool inherit, uint flags, IntPtr env, string cwd, ref SI si, out PI pi);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool CreateProcessWithTokenW(IntPtr tok, uint logon, string app, StringBuilder cmd,
        uint flags, IntPtr env, string cwd, ref SI si, out PI pi);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta,
        bool inherit, uint flags, IntPtr env, string cwd, ref SI si, out PI pi);
    [DllImport("advapi32.dll", SetLastError=true)] static extern int GetLengthSid(IntPtr sid);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);

    static string SidStr(IntPtr sid)
    {
        IntPtr s; if (!ConvertSidToStringSidW(sid, out s)) return "?";
        string r = Marshal.PtrToStringUni(s); LocalFree(s); return r;
    }
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern bool ConvertSidToStringSidW(IntPtr sid, out IntPtr str);

    static void Main(string[] args)
    {
        string target = null, targs = "", self = "keep", sids = "logon,everyone,write";
        string outFile = null, cwd = Environment.CurrentDirectory, writeSid = "S-1-4-1234-5678-9012-3456";
        int flags = 0; uint tflags = 13; int low = 1, restrict = 1, withToken = 0, defdacl = 0, appNull = 0, noInherit = 0;
        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "-Target": target = args[++i]; break;
                case "-TArgs": targs = args[++i]; break;
                case "-Self": self = args[++i]; break;
                case "-Sids": sids = args[++i]; break;
                case "-Flags": flags = unchecked((int)Convert.ToUInt32(args[++i], 16)); break;
                case "-TFlags": tflags = Convert.ToUInt32(args[++i], 16); break;
                case "-Low": low = int.Parse(args[++i]); break;
                case "-Restrict": restrict = int.Parse(args[++i]); break;
                case "-WithToken": withToken = int.Parse(args[++i]); break;
                case "-DefDacl": defdacl = int.Parse(args[++i]); break;
                case "-Out": outFile = args[++i]; break;
                case "-Cwd": cwd = args[++i]; break;
                case "-WriteSid": writeSid = args[++i]; break;
                case "-AppNull": appNull = 1; break;
                case "-NoInherit": noInherit = 1; break;
            }
        }

        if (self == "detach") { FreeConsole(); }
        else if (self == "alloc") { AllocConsole(); }

        bool hasConsole = GetConsoleWindow() != IntPtr.Zero;
        var log = new StringBuilder();
        log.AppendFormat("self={0} console={1} restrict={2} low={3} sids={4} tflags=0x{5:X} cflags=0x{6:X} withToken={7}\n",
            self, hasConsole, restrict, low, sids, tflags, flags, withToken);

        IntPtr tok = IntPtr.Zero;
        var keep = new System.Collections.Generic.List<IntPtr>();
        if (restrict == 1 || low == 1)
        {
            if (!OpenProcessToken(GetCurrentProcess(), 0xF01FF, out tok)) { log.AppendLine("OpenProcessToken fail " + Marshal.GetLastWin32Error()); Console.Write(log); return; }
            if (restrict == 1)
            {
                int need; GetTokenInformation(tok, 2, IntPtr.Zero, 0, out need);
                IntPtr g = Marshal.AllocHGlobal(need);
                if (!GetTokenInformation(tok, 2, g, need, out need)) { log.AppendLine("GetTokenInformation fail " + Marshal.GetLastWin32Error()); Console.Write(log); return; }
                uint count = (uint)Marshal.ReadInt32(g);
                IntPtr found = IntPtr.Zero;
                for (uint k = 0; k < count; k++)
                {
                    IntPtr entry = (IntPtr)((long)g + 8 + k * 16);
                    uint attr = (uint)Marshal.ReadInt32(entry, 8);
                    if ((attr & 0xC0000000) == 0xC0000000) { found = Marshal.ReadIntPtr(entry); break; }
                }
                var list = new System.Collections.Generic.List<SIA>();
                foreach (var name in sids.Split(','))
                {
                    IntPtr sid;
                    if (name == "logon")
                    {
                        if (found == IntPtr.Zero) { log.AppendLine("no logon sid"); Console.Write(log); return; }
                        IntPtr str; ConvertSidToStringSidW(found, out str);
                        string s = Marshal.PtrToStringUni(str);
                        ConvertStringSidToSidW(s, out sid);
                        log.AppendLine("logon=" + s);
                    }
                    else if (name == "everyone") ConvertStringSidToSidW("S-1-1-0", out sid);
                    else if (name == "write") ConvertStringSidToSidW(writeSid, out sid);
                    else { ConvertStringSidToSidW(name, out sid); }
                    keep.Add(sid);
                    list.Add(new SIA { Sid = sid, Attr = 0 });
                }
                IntPtr nt;
                if (!CreateRestrictedToken(tok, tflags, 0, IntPtr.Zero, 0, IntPtr.Zero, (uint)list.Count, list.ToArray(), out nt))
                { log.AppendLine("CreateRestrictedToken fail " + Marshal.GetLastWin32Error()); Console.Write(log); return; }
                CloseHandle(tok); tok = nt;
                log.AppendLine("restricted ok sids=" + string.Join(",", list.ConvertAll(x => SidStr(x.Sid)).ToArray()));
            }
            if (low == 1)
            {
                IntPtr lowSid; ConvertStringSidToSidW("S-1-16-4096", out lowSid);
                int len = 16 + GetLengthSid(lowSid);
                IntPtr info = Marshal.AllocHGlobal(len);
                Marshal.StructureToPtr(new SIA { Sid = lowSid, Attr = 0x20 }, info, false);
                if (!SetTokenInformation(tok, 25, info, len))
                { log.AppendLine("SetTokenInfo(TIL) fail " + Marshal.GetLastWin32Error()); Console.Write(log); return; }
                log.AppendLine("low IL set");
            }
        }

        var sa = new SA { nLength = Marshal.SizeOf(typeof(SA)), inherit = 1 };
        IntPtr hOut = CreateFileW(outFile, 0x40000000, 3, ref sa, 2, 0, IntPtr.Zero);
        IntPtr hIn = CreateFileW("NUL", 0x80000000, 3, ref sa, 3, 0, IntPtr.Zero);
        var si = new SI { cb = Marshal.SizeOf(typeof(SI)), flags = noInherit == 1 ? 0 : 0x100, hIn = hIn, hOut = hOut, hErr = hOut };
        var pi = new PI();

        string full = "\"" + target + "\" " + targs; log.AppendLine("cwd=" + cwd + " cmd=" + full + " appNull=" + appNull + " noInherit=" + noInherit + " hOut=0x" + hOut.ToInt64().ToString("X"));
        var cmd = new StringBuilder(full);
        bool ok;
        if (restrict == 0 && low == 0)
            ok = CreateProcessW(appNull == 1 ? null : target, cmd, IntPtr.Zero, IntPtr.Zero, noInherit == 0, (uint)flags, IntPtr.Zero, cwd, ref si, out pi);
        else if (withToken == 1)
            ok = CreateProcessWithTokenW(tok, 0, appNull == 1 ? null : target, cmd, (uint)flags, IntPtr.Zero, cwd, ref si, out pi);
        else
            ok = CreateProcessAsUserW(tok, appNull == 1 ? null : target, cmd, IntPtr.Zero, IntPtr.Zero, noInherit == 0, (uint)flags, IntPtr.Zero, cwd, ref si, out pi);

        if (!ok)
        {
            log.AppendLine("CreateProcess FAIL " + Marshal.GetLastWin32Error());
            CloseHandle(hOut); CloseHandle(hIn);
            Console.Write(log); return;
        }
        WaitForSingleObject(pi.hP, 0xFFFFFFFF);
        uint code; GetExitCodeProcess(pi.hP, out code);
        CloseHandle(pi.hP); CloseHandle(pi.hT); CloseHandle(hOut); CloseHandle(hIn);

        string text = "";
        try { text = System.IO.File.ReadAllText(outFile); } catch { }
        log.AppendFormat("exit=0x{0:X8} ({0}) out=[{1}]\n", code, text.Replace("\r", "").Replace("\n", "\\n"));
        Console.Write(log);
    }
}

