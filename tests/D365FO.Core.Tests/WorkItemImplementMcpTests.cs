using System.Text.Json;
using D365FO.Mcp;
using D365FO.Core;
using Xunit;

namespace D365FO.Core.Tests;

public class WorkItemImplementMcpTests
{
    [Fact]
    public void WorkItem_journal_tool_is_local_and_write_gated()
    {
        var descriptor = ToolCatalog.All.Single(d => d.Name == "workitem_implement");
        Assert.Equal("workitem_implement", descriptor.Name);
        Assert.Contains("workitem_implement", ToolCatalog.WriteTools);
        Assert.False(ServerModeConfig.IsToolAllowed(McpServerMode.ReadOnly, "workitem_implement"));
        Assert.True(ServerModeConfig.IsToolAllowed(McpServerMode.Full, "workitem_implement"));
    }

    [Fact]
    public void No_arbitrary_process_execution_actions_are_exposed()
    {
        using var input = JsonDocument.Parse("""{"action":"shell","path":"whoami"}""");
        var result = WorkItemImplementTool.Run(input.RootElement);
        using var output = JsonDocument.Parse(D365Json.Serialize(result));
        Assert.False(output.RootElement.GetProperty("ok").GetBoolean());
        Assert.Equal("BAD_INPUT", output.RootElement.GetProperty("error").GetProperty("code").GetString());
    }

    [Fact]
    public void Canonical_validation_receipt_is_forwarded_only_as_declared_arguments()
    {
        using var input = JsonDocument.Parse("""
            {"action":"record-validation","validationId":"V001","validationStatus":"PASS",
             "receiptPath":"AxEdt/ConRequestId.xml","receiptSha256":"abc"}
            """);
        var argv = WorkItemImplementTool.BuildArguments(input.RootElement,
            "lifecycle_state.py", "/workitems/64120", "/project");
        Assert.Equal("lifecycle_state.py", argv[0]);
        Assert.Equal("implement-record-validation", argv[1]);
        Assert.Contains("--workitem-root", argv);
        Assert.Contains("--project-root", argv);
        Assert.Contains("--validation-id", argv);
        Assert.Contains("--receipt-sha256", argv);
        Assert.Equal("PASS", argv[argv.IndexOf("--status") + 1]);
        Assert.DoesNotContain("shell", argv);
    }

    [Theory]
    [InlineData("OK")]
    [InlineData("PASSED")]
    [InlineData("")]
    public void Noncanonical_validation_status_is_refused(string status)
    {
        using var input = JsonDocument.Parse(
            "{\"action\":\"record-validation\",\"validationId\":\"V001\",\"validationStatus\":\""+status+"\"}");
        Assert.Throws<ArgumentException>(() =>
            WorkItemImplementTool.BuildArguments(input.RootElement, "lifecycle_state.py", "/w", "/p"));
    }

    [Fact]
    public void Plan_registration_cannot_escape_operator_pinned_WorkItem_directory()
    {
        using var input = JsonDocument.Parse("""{"action":"register-plan","planFile":"../outside.json"}""");
        Assert.Throws<ArgumentException>(() =>
            WorkItemImplementTool.BuildArguments(input.RootElement, "lifecycle_state.py",
                Path.Combine(Path.GetTempPath(), "workitem-test"), Path.GetTempPath()));
    }
    [Fact]
    public void WorkItem_resolution_uses_only_the_authoritative_project_index()
    {
        var root = Path.Combine(Path.GetTempPath(), "wim-index-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            Directory.CreateDirectory(Path.Combine(root, "64120 - CR Consolidation"));
            File.WriteAllText(Path.Combine(root, "index.json"),
                """{"64120":"64120 - CR Consolidation","64121":"../outside"}""");
            Assert.Equal(Path.Combine(root, "64120 - CR Consolidation"),
                WorkItemImplementTool.ResolveWorkItemRoot(root, "64120"));
            Assert.Throws<ArgumentException>(() =>
                WorkItemImplementTool.ResolveWorkItemRoot(root, "64121"));
            Assert.Throws<ArgumentException>(() =>
                WorkItemImplementTool.ResolveWorkItemRoot(root, "../64120"));
            Assert.Throws<ArgumentException>(() =>
                WorkItemImplementTool.ResolveWorkItemRoot(root, "64122"));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

}
