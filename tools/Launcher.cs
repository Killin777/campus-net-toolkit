// 单文件启动器；原始 v1.2 启动壳已保存在 _qa/before/tools。
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: AssemblyTitle("校园网工具箱")]
[assembly: AssemblyVersion("1.3.0.0")]
[assembly: AssemblyFileVersion("1.3.0.0")]

public sealed class PackageFile { public string path; public string sha256; }
public sealed class PackageManifest { public string version; public PackageFile[] files; }
public sealed class StartupPreference { public int schemaVersion = 1; public bool? alwaysRunAsAdmin; }

public static class Launcher
{
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    static readonly string Self = Assembly.GetExecutingAssembly().Location;
    static readonly string DataRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CampusNetToolkit");

    [STAThread]
    public static int Main(string[] args)
    {
        Application.EnableVisualStyles();
        try
        {
            if (args.Length == 2 && (args[0] == "--verify-package" || args[0] == "--smoke-test"))
            {
                string target = Path.GetFullPath(args[1]);
                string app = Path.Combine(target, "app");
                var manifest = ReadManifest();
                Extract(app, manifest);
                File.WriteAllText(Path.Combine(target, "package-info.json"), Json.Serialize(manifest), new UTF8Encoding(false));
                if (args[0] == "--verify-package") return 0;
                foreach (string screen in new[] { "Screenshot", "Settings", "Timeline", "Help" })
                {
                    int code = RunGui(app, Path.Combine(target, "data"), new[] { "-" + screen, "-Out", Path.Combine(target, screen + ".png") }, true);
                    if (code != 0) return code;
                }
                return 0;
            }
            if (args.Length == 1 && args[0] == "--startup-settings")
            {
                ChoosePreference(Path.Combine(DataRoot, "runtime", "launcher.json"));
                return 0;
            }
            bool adminRequested = args.Length >= 1 && args[0] == "--admin";
            if ((args.Length != 0 && !adminRequested) || args.Length > 2)
                throw new ArgumentException("不支持的启动参数。正常使用请直接双击 EXE。");

            bool owned = false;
            string sid = WindowsIdentity.GetCurrent().User.Value;
            if (adminRequested && args.Length == 2 && args[1] != sid)
                throw new InvalidOperationException("管理员凭据属于另一 Windows 用户，不能替原用户管理代理与还原记录。请使用原账号的管理员授权，或通过 --startup-settings 选择普通权限启动。");
            using (var mutex = new Mutex(false, @"Local\CampusNetToolkit-" + sid))
            {
                try
                {
                    try { owned = mutex.WaitOne(15000); } catch (AbandonedMutexException) { owned = true; }
                    if (!owned)
                    {
                        MessageBox.Show("网络优化器已经在运行，请从任务栏切换到现有窗口。", "校园网工具箱", MessageBoxButtons.OK, MessageBoxIcon.Information);
                        return 0;
                    }
                    string preferencePath = Path.Combine(DataRoot, "runtime", "launcher.json");
                    bool? preference = LoadPreference(preferencePath);
                    if (!preference.HasValue && !adminRequested) preference = ChoosePreference(preferencePath);
                    if (!preference.HasValue && !adminRequested) return 0;
                    if ((preference == true || adminRequested) && !IsAdmin())
                    {
                        try
                        {
                            Process.Start(new ProcessStartInfo(Self, "--admin " + QuoteArgument(sid)) { UseShellExecute = true, Verb = "runas", WorkingDirectory = Path.GetDirectoryName(Self) });
                            return 0;
                        }
                        catch (Win32Exception ex)
                        {
                            if (ex.NativeErrorCode != 1223) throw;
                            MessageBox.Show("已取消管理员授权，程序尚未启动。下次双击可重试；启动偏好可在设置中修改。", "校园网工具箱", MessageBoxButtons.OK, MessageBoxIcon.Information);
                            return 0;
                        }
                    }
                    ImportLegacyData(Path.GetDirectoryName(Self), DataRoot);
                    var manifest = ReadManifest();
                    string cache = Path.Combine(DataRoot, "app", manifest.version + "-" + ManifestHash().Substring(0, 12));
                    if (!Verify(cache, manifest))
                    {
                        Extract(cache, manifest);
                    }
                    return RunGui(cache, DataRoot, new string[0], false);
                }
                finally { if (owned) mutex.ReleaseMutex(); }
            }
        }
        catch (Exception ex)
        {
            if (args.Length == 2 && (args[0] == "--verify-package" || args[0] == "--smoke-test"))
            {
                try { Directory.CreateDirectory(args[1]); File.WriteAllText(Path.Combine(args[1], "error.txt"), ex.ToString(), Encoding.UTF8); } catch { }
                return 1;
            }
            MessageBox.Show("启动失败：" + ex.Message, "校园网工具箱", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    public static bool? LoadPreference(string path)
    {
        if (!File.Exists(path)) return null;
        try
        {
            var value = Json.Deserialize<StartupPreference>(File.ReadAllText(path));
            return value != null && value.schemaVersion == 1 ? value.alwaysRunAsAdmin : null;
        }
        catch { return null; }
    }

    public static void SavePreference(string path, bool value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path));
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temporary, Json.Serialize(new StartupPreference { alwaysRunAsAdmin = value }), new UTF8Encoding(false));
            if (File.Exists(path)) File.Replace(temporary, path, null);
            else File.Move(temporary, path);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    static bool? ChoosePreference(string path)
    {
        var choice = MessageBox.Show(
            "是否以后默认以管理员权限启动网络优化器？\n\n" +
            "是：记住选择，每次启动按 Windows 规则请求管理员授权。\n" +
            "否：记住普通权限启动，体检、代理管理等功能仍可用。\n" +
            "取消：本次退出，下次再询问。\n\nWindows 的 UAC 提示仍可能出现。可在程序设置中修改此偏好。",
            "启动权限偏好", MessageBoxButtons.YesNoCancel, MessageBoxIcon.Question);
        return ApplyPreferenceChoice(path, choice);
    }

    public static bool? ApplyPreferenceChoice(string path, DialogResult choice)
    {
        if (choice == DialogResult.Cancel) return null;
        if (choice != DialogResult.Yes && choice != DialogResult.No) throw new ArgumentException("无效的权限选择。");
        bool value = choice == DialogResult.Yes;
        SavePreference(path, value);
        return value;
    }

    public static void ImportLegacyData(string legacyRoot, string dataRoot)
    {
        string marker = Path.Combine(dataRoot, "runtime", "legacy-import-v1.json");
        if (File.Exists(marker)) return;
        if (!Directory.Exists(Path.Combine(legacyRoot, "config")) && !Directory.Exists(Path.Combine(legacyRoot, "runtime"))) return;
        var relativeFiles = new List<string> {
            @"config\proxy-config.json", @"config\campus-config.json", @"runtime\proxy-settings.json",
            @"runtime\mode-state.json", @"runtime\proxy-backup.json", @"runtime\dns-backup.json", @"runtime\link-events-ignore.json"
        };
        string oldRuntime = Path.Combine(legacyRoot, "runtime");
        if (Directory.Exists(oldRuntime))
            foreach (string pattern in new[] { "network-backup-*.json", "wifi-backup-*.json" })
                foreach (string path in Directory.GetFiles(oldRuntime, pattern)) relativeFiles.Add(Path.Combine("runtime", Path.GetFileName(path)));
        int imported = 0;
        foreach (string relative in relativeFiles)
        {
            string source = SafePath(legacyRoot, relative);
            string destinationRelative = relative.StartsWith("config\\", StringComparison.OrdinalIgnoreCase)
                ? Path.Combine("runtime", "imported-" + Path.GetFileName(relative)) : relative;
            string destination = SafePath(dataRoot, destinationRelative);
            if (!File.Exists(source) || File.Exists(destination)) continue;
            Directory.CreateDirectory(Path.GetDirectoryName(destination));
            File.Copy(source, destination, false);
            imported++;
        }
        Directory.CreateDirectory(Path.GetDirectoryName(marker));
        File.WriteAllText(marker, Json.Serialize(new { imported = imported, completedUtc = DateTime.UtcNow.ToString("o") }), new UTF8Encoding(false));
    }

    static bool IsAdmin()
    {
        using (var id = WindowsIdentity.GetCurrent())
            return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
    }

    static string ReadResource(string name)
    {
        using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
        {
            if (stream == null) throw new InvalidDataException("发布包缺少资源：" + name);
            using (var reader = new StreamReader(stream, Encoding.UTF8)) return reader.ReadToEnd();
        }
    }
    static PackageManifest ReadManifest()
    {
        var manifest = Json.Deserialize<PackageManifest>(ReadResource("Toolkit.Manifest.json"));
        if (manifest == null || manifest.files == null || manifest.files.Length == 0 ||
            String.IsNullOrEmpty(manifest.version) || manifest.version.Any(c => !Char.IsDigit(c) && c != '.'))
            throw new InvalidDataException("发布清单无效。");
        return manifest;
    }
    static string ManifestHash()
    {
        using (var hash = SHA256.Create()) return Hex(hash.ComputeHash(Encoding.UTF8.GetBytes(ReadResource("Toolkit.Manifest.json"))));
    }
    static string Hex(byte[] bytes) { return BitConverter.ToString(bytes).Replace("-", "").ToLowerInvariant(); }
    static string SafePath(string root, string relative)
    {
        string basePath = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        string candidate = Path.GetFullPath(Path.Combine(basePath, relative.Replace('/', Path.DirectorySeparatorChar)));
        if (Path.IsPathRooted(relative) || !candidate.StartsWith(basePath, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("发布文件路径越界。");
        return candidate;
    }
    static bool Verify(string root, PackageManifest manifest)
    {
        foreach (var item in manifest.files)
        {
            string path = SafePath(root, item.path);
            if (!File.Exists(path)) return false;
            using (var hash = SHA256.Create())
            using (var input = File.OpenRead(path))
                if (!String.Equals(Hex(hash.ComputeHash(input)), item.sha256, StringComparison.OrdinalIgnoreCase)) return false;
        }
        return true;
    }
    static void Extract(string root, PackageManifest manifest)
    {
        Directory.CreateDirectory(root);
        var expected = manifest.files.ToDictionary(f => f.path, StringComparer.OrdinalIgnoreCase);
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        using (var input = Assembly.GetExecutingAssembly().GetManifestResourceStream("Toolkit.Payload.zip"))
        using (var archive = new ZipArchive(input, ZipArchiveMode.Read))
        {
            foreach (var entry in archive.Entries)
            {
                if (!expected.ContainsKey(entry.FullName) || !seen.Add(entry.FullName)) throw new InvalidDataException("发布内容与清单不匹配。");
                string path = SafePath(root, entry.FullName);
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                using (var source = entry.Open())
                using (var output = File.Create(path)) source.CopyTo(output);
            }
        }
        if (seen.Count != expected.Count || !Verify(root, manifest)) throw new InvalidDataException("程序资源校验失败，请重新获取完整 EXE。");
    }

    public static string QuoteArgument(string value)
    {
        var result = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in value)
        {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') { result.Append('\\', slashes * 2 + 1); result.Append('"'); }
            else { result.Append('\\', slashes); result.Append(c); }
            slashes = 0;
        }
        result.Append('\\', slashes * 2);
        return result.Append('"').ToString();
    }
    static int RunGui(string appRoot, string dataRoot, string[] extraArgs, bool smoke)
    {
        Directory.CreateDirectory(Path.Combine(dataRoot, "runtime"));
        string logPath = Path.Combine(dataRoot, "runtime", "launcher-" + DateTime.Now.ToString("yyyyMMdd-HHmmss-fff") + ".log");
        string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
        var arguments = new List<string> { "-NoProfile", "-STA", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", Path.Combine(appRoot, @"src\网络优化器.ps1") };
        arguments.AddRange(extraArgs);
        var start = new ProcessStartInfo(powershell, String.Join(" ", arguments.Select(QuoteArgument))) {
            WorkingDirectory = appRoot, UseShellExecute = false, CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = new UTF8Encoding(false), StandardErrorEncoding = new UTF8Encoding(false)
        };
        start.EnvironmentVariables["CAMPUS_NET_DATA_ROOT"] = dataRoot;
        start.EnvironmentVariables["CAMPUS_NET_LAUNCHER"] = Self;
        if (smoke) start.EnvironmentVariables["CAMPUS_NET_SMOKE"] = "1";
        int code;
        using (var output = new StreamWriter(logPath, false, new UTF8Encoding(true)))
        using (var process = new Process { StartInfo = start })
        {
            object sync = new object();
            process.OutputDataReceived += (s, e) => { if (e.Data != null) lock (sync) { output.WriteLine(e.Data); output.Flush(); } };
            process.ErrorDataReceived += (s, e) => { if (e.Data != null) lock (sync) { output.WriteLine(e.Data); output.Flush(); } };
            process.Start();
            process.BeginOutputReadLine(); process.BeginErrorReadLine();
            if (smoke && !process.WaitForExit(90000)) { process.Kill(); throw new TimeoutException("界面验收超时，详见 " + logPath); }
            process.WaitForExit();
            code = process.ExitCode;
        }
        if (code != 0 && !smoke) MessageBox.Show("主程序异常退出（代码 " + code + "）。\n\n错误记录：" + logPath, "校园网工具箱", MessageBoxButtons.OK, MessageBoxIcon.Error);
        return code;
    }
}
