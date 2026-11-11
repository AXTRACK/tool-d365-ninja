import importlib.util
from pathlib import Path

path = Path(__file__).with_name("emit-mcp-tools.py")
spec = importlib.util.spec_from_file_location("emit_mcp_tools", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

commands = [{"command": "inspect", "mcpTool": ["inspect"]}]
tools = [{"name": "inspect", "description": "Inspect"},
         {"name": "workitem_implement", "description": "Operator journal"}]
rendered = module.render(commands, tools)
assert "### `workitem_implement`" in rendered
assert "*(MCP-only operator workflow)*" in rendered

try:
    module.render(commands, tools + [{"name": "unexpected_tool", "description": "Unexpected"}])
except SystemExit as error:
    assert error.code == 1
else:
    raise AssertionError("Unknown orphan MCP tool must fail")

print("MCP_TOOL_MAP_PARITY_PASS")