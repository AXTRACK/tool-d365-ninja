using System.Diagnostics;
using System.Text.Json;
using D365FO.Core;

namespace D365FO.Mcp;

/// <summary>
/// Narrow adapter to the existing AXTRACK/Codex Implement lifecycle CLI.
/// This class never owns lifecycle state and never accepts executable/script/root paths
/// from MCP clients. The canonical lifecycle_state.py validates every transition.
/// </summary>
public static class WorkItemImplementTool
{
    private static readonly HashSet<string> Actions = new(StringComparer.Ordinal)
    {
        "status", "register-plan", "begin", "record-target", "skip-target",
        "record-validation", "recover-complete", "complete"
    };

    public static ToolResult<object> Run(JsonElement request)
    {
        var action = Text(request, "action");
        if (!Actions.Contains(action))
            return ToolResult<object>.Fail("BAD_INPUT", $"Unsupported Implement action '{action}'.",
                "Use status, register-plan, begin, record-target, skip-target, record-validation, recover-complete, or complete.");

        // Operator-owned configuration only; MCP clients cannot select an arbitrary
        // script, Python executable, project root or WorkItem root.
        var script = Environment.GetEnvironmentVariable("D365FO_IMPLEMENT_LIFECYCLE_SCRIPT");
        var workitemRoot = Environment.GetEnvironmentVariable("D365FO_IMPLEMENT_WORKITEM_ROOT");
        var projectRoot = Environment.GetEnvironmentVariable("D365FO_IMPLEMENT_PROJECT_ROOT");
        var python = Environment.GetEnvironmentVariable("D365FO_IMPLEMENT_PYTHON") ?? "python";

        if (string.IsNullOrWhiteSpace(script) || !Path.IsPathFullyQualified(script) ||
            !File.Exists(script) || !Path.GetFileName(script).Equals("lifecycle_state.py", StringComparison.OrdinalIgnoreCase) ||
            string.IsNullOrWhiteSpace(workitemRoot) || !Path.IsPathFullyQualified(workitemRoot) ||
            !Directory.Exists(workitemRoot) ||
            string.IsNullOrWhiteSpace(projectRoot) || !Path.IsPathFullyQualified(projectRoot) ||
            !Directory.Exists(projectRoot))
            return ToolResult<object>.Fail("LIFECYCLE_NOT_CONFIGURED",
                "WorkItem Implement adapter requires operator-pinned lifecycle_state.py, WorkItem root and project root.",
                "Set D365FO_IMPLEMENT_LIFECYCLE_SCRIPT, D365FO_IMPLEMENT_WORKITEM_ROOT and D365FO_IMPLEMENT_PROJECT_ROOT on the local Ninja MCP process.");

        List<string> arguments;
        try { arguments = BuildArguments(request, script, workitemRoot, projectRoot); }
        catch (ArgumentException ex) { return ToolResult<object>.Fail("BAD_INPUT", ex.Message); }

        try
        {
            using var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = python,
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true,
                }
            };
            foreach (var argument in arguments) process.StartInfo.ArgumentList.Add(argument);

            if (!process.Start())
                return ToolResult<object>.Fail("LIFECYCLE_EXEC_FAILED", "Could not start the configured Python runtime.");

            var outputTask = process.StandardOutput.ReadToEndAsync();
            var errorTask = process.StandardError.ReadToEndAsync();
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(45));
            try { process.WaitForExitAsync(timeout.Token).GetAwaiter().GetResult(); }
            catch (OperationCanceledException)
            {
                if (!process.HasExited) process.Kill(entireProcessTree: true);
                return ToolResult<object>.Fail("LIFECYCLE_TIMEOUT",
                    "Canonical Implement helper did not finish in the bounded execution window; check the journal before retrying.");
            }

            var output = outputTask.GetAwaiter().GetResult();
            var error = errorTask.GetAwaiter().GetResult();
            if (process.ExitCode != 0)
                return ToolResult<object>.Fail("LIFECYCLE_BLOCKED",
                    $"Canonical Implement helper exited {process.ExitCode}: {error.Trim()}");

            using var parsed = JsonDocument.Parse(output);
            return ToolResult<object>.Success(parsed.RootElement.Clone());
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or IOException or JsonException or InvalidOperationException)
        {
            return ToolResult<object>.Fail("LIFECYCLE_EXEC_FAILED", ex.Message);
        }
    }

    /// <summary>Build only supported canonical CLI commands. No shell invocation or free-form argv.</summary>
    public static List<string> BuildArguments(
        JsonElement request, string script, string workitemRoot, string projectRoot)
    {
        var action = Text(request, "action");
        var verb = action switch
        {
            "status" => "implement-status",
            "register-plan" => "implement-register-plan",
            "begin" => "implement-begin",
            "record-target" => "implement-record-target",
            "skip-target" => "implement-skip-target",
            "record-validation" => "implement-record-validation",
            "recover-complete" => "implement-recover-complete",
            "complete" => "implement-complete",
            _ => throw new ArgumentException("Unknown Implement action")
        };

        var result = new List<string> { script, verb, "--workitem-root", workitemRoot };
        // skip-target is deliberately workitem-only in the canonical CLI.
        if (action != "skip-target")
        {
            result.Add("--project-root");
            result.Add(projectRoot);
        }
        result.Add("--json");

        void Required(string property, string flag)
        {
            var value = Text(request, property);
            if (string.IsNullOrWhiteSpace(value))
                throw new ArgumentException($"'{property}' is required for action '{action}'.");
            result.Add(flag);
            result.Add(value);
        }
        void Optional(string property, string flag)
        {
            var value = Text(request, property);
            if (!string.IsNullOrWhiteSpace(value))
            {
                result.Add(flag);
                result.Add(value);
            }
        }

        switch (action)
        {
            case "register-plan":
            {
                var relative = Text(request, "planFile");
                if (string.IsNullOrWhiteSpace(relative) || Path.IsPathFullyQualified(relative))
                    throw new ArgumentException("planFile must be relative to the configured WorkItem root.");
                var basePath = Path.GetFullPath(workitemRoot);
                var resolved = Path.GetFullPath(Path.Combine(basePath, relative));
                if (!resolved.StartsWith(basePath.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar,
                        StringComparison.OrdinalIgnoreCase) || !File.Exists(resolved))
                    throw new ArgumentException("planFile must be an existing file under the configured WorkItem root.");
                result.Add("--plan-file");
                result.Add(resolved);
                break;
            }
            case "begin":
                Required("path", "--path");
                Optional("targetId", "--target-id");
                Optional("reconciledSha256", "--reconciled-sha256");
                Optional("reconciliationEvidence", "--reconciliation-evidence");
                break;
            case "record-target":
                Required("targetId", "--target-id");
                Optional("receiptPath", "--receipt-path");
                Optional("receiptSha256", "--receipt-sha256");
                if (Flag(request, "deleted")) result.Add("--deleted");
                break;
            case "skip-target":
                Required("targetId", "--target-id");
                Required("reason", "--reason");
                Required("evidence", "--evidence");
                break;
            case "record-validation":
                Required("validationId", "--validation-id");
                var status = Text(request, "validationStatus");
                if (status is not ("PASS" or "FAILED" or "NOT_RUN"))
                    throw new ArgumentException("validationStatus must be PASS, FAILED, or NOT_RUN.");
                result.Add("--status");
                result.Add(status);
                Optional("receiptPath", "--receipt-path");
                Optional("receiptSha256", "--receipt-sha256");
                break;
            case "complete":
                break;
        }
        return result;
    }

    private static string Text(JsonElement root, string name) =>
        root.ValueKind == JsonValueKind.Object &&
        root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() ?? "" : "";

    private static bool Flag(JsonElement root, string name) =>
        root.ValueKind == JsonValueKind.Object &&
        root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.True;
}
