[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CandidateSourceRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Utf8NoBom {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Content)
    $parent = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path,$Content,[Text.UTF8Encoding]::new($false))
}

function Add-OverlayFile {
    param([Parameter(Mandatory)][string]$RelativePath,[Parameter(Mandatory)][string]$Content)
    $path = Join-Path $CandidateSourceRoot $RelativePath
    if (Test-Path -LiteralPath $path) {
        throw "NINJA_OVERLAY_CONFLICT: overlay add target already exists: $RelativePath"
    }
    Write-Utf8NoBom -Path $path -Content $Content
}

function Replace-Exact {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Old,
        [Parameter(Mandatory)][string]$New
    )
    $path = Join-Path $CandidateSourceRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "NINJA_OVERLAY_TARGET_MISSING: $RelativePath"
    }
    $content = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $first = $content.IndexOf($Old,[StringComparison]::Ordinal)
    if ($first -lt 0) {
        throw "NINJA_OVERLAY_CONTEXT_MISMATCH: expected context not found in $RelativePath"
    }
    if ($content.IndexOf($Old,$first + $Old.Length,[StringComparison]::Ordinal) -ge 0) {
        throw "NINJA_OVERLAY_CONTEXT_AMBIGUOUS: expected context occurs more than once in $RelativePath"
    }
    $updated = $content.Substring(0,$first) + $New + $content.Substring($first + $Old.Length)
    Write-Utf8NoBom -Path $path -Content $updated
}

# Integrate AXTRACK form-control mutations into the upstream ObjectModifyEngine batch model.
# The upstream engine already guarantees one read/edit-write + one journal entry for a same-object
# batch. Extending that existing operation model avoids a second batching implementation.

Replace-Exact 'src\D365FO.Core\Bridge\ObjectModifyEngine.cs' @'
        /// <summary>Add a control to a form's Design tree.</summary>
        AddControl,

        /// <summary>Add an index to a table.</summary>
'@ @'
        /// <summary>Add a control to a form's Design tree.</summary>
        AddControl,

        /// <summary>Set one approved property on an existing form control.</summary>
        SetControlProperty,

        /// <summary>Move one existing inline form control immediately before a sibling.</summary>
        PlaceControlBefore,

        /// <summary>Move one existing control immediately after a sibling.</summary>
        PlaceControlAfter,

        /// <summary>Add an index to a table.</summary>
'@

Replace-Exact 'src\D365FO.Core\Bridge\ObjectModifyEngine.cs' @'
        public string? DataField { get; init; }

        /// <summary>Owning model. Resolved from the index when omitted.</summary>
'@ @'
        public string? DataField { get; init; }

        /// <summary>Approved metadata property for SetControlProperty.</summary>
        public string? ControlProperty { get; init; }

        /// <summary>Sibling control for PlaceControlBefore / PlaceControlAfter.</summary>
        public string? Sibling { get; init; }

        /// <summary>Owning model. Resolved from the index when omitted.</summary>
'@

Replace-Exact 'src\D365FO.Core\Bridge\ObjectModifyEngine.cs' @'
            Operation.AddControl => AddControl(doc, request),
            Operation.AddIndex => AddIndex(doc, request),
'@ @'
            Operation.AddControl => AddControl(doc, request),
            Operation.SetControlProperty => ApplyFormControlOperation(doc, request),
            Operation.PlaceControlBefore => ApplyFormControlOperation(doc, request),
            Operation.PlaceControlAfter => ApplyFormControlOperation(doc, request),
            Operation.AddIndex => AddIndex(doc, request),
'@

Replace-Exact 'src\D365FO.Core\Bridge\ObjectModifyEngine.cs' @'
            Operation.AddControl when string.IsNullOrWhiteSpace(request.Type) =>
                ToolResult<object>.Fail(D365FoErrorCodes.BadInput,
                    "--type is required for `modify add-control` (Grid, Group, TabPage, String, …)."),

            // ---- table-shaped operations ----
'@ @'
            Operation.AddControl when string.IsNullOrWhiteSpace(request.Type) =>
                ToolResult<object>.Fail(D365FoErrorCodes.BadInput,
                    "--type is required for modify add-control (Grid, Group, TabPage, String, …)."),
            Operation.SetControlProperty or Operation.PlaceControlBefore or Operation.PlaceControlAfter
                when kind is not ("form" or "formextension") =>
                ToolResult<object>.Fail(D365FoErrorCodes.BadInput,
                    $"Form-control operation {CommandNameFor(request.Operation)} applies to forms/form extensions, not {kind}."),
            Operation.SetControlProperty when string.IsNullOrWhiteSpace(request.ControlProperty) =>
                ToolResult<object>.Fail(D365FoErrorCodes.BadInput,
                    "\"property\" is required for a control-property batch step."),
            Operation.SetControlProperty when request.Value is null =>
                ToolResult<object>.Fail(D365FoErrorCodes.BadInput,
                    "\"value\" is required for a control-property batch step."),
            Operation.PlaceControlBefore or Operation.PlaceControlAfter when string.IsNullOrWhiteSpace(request.Sibling) =>
                ToolResult<object>.Fail(D365FoErrorCodes.BadInput,
                    "\"sibling\" is required for a control-placement batch step."),

            // ---- table-shaped operations ----
'@

Replace-Exact 'src\D365FO.Core\Bridge\ObjectModifyEngine.cs' @'
        Operation.AddControl => "add-control",
        Operation.AddIndex => "add-index",
'@ @'
        Operation.AddControl => "add-control",
        Operation.SetControlProperty => "control-property",
        Operation.PlaceControlBefore => "control-before",
        Operation.PlaceControlAfter => "control-after",
        Operation.AddIndex => "add-index",
'@

Replace-Exact 'src\D365FO.Core\Bridge\ObjectModifyEngine.cs' @'
    /// <summary>Find a container control by name anywhere in the design tree; null name means the design root.</summary>
    private static XElement? FindContainer(XElement design, string? name)
'@ @'
    private static readonly IReadOnlySet<string> AllowedControlProperties =
        new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "ExtendedDataType",
            "Label",
            "AutoDeclaration",
            "ReplaceOnLookup",
            "DataSource",
            "DataField",
            "DataMethod",
            "Caption",
            "Text",
            "CountryRegionCodes",
            "AllowEdit",
            "Enabled",
            "Visible",
        };

    internal sealed record LocatedFormControl(XElement PropertyNode, XElement PlacementNode, bool ExtensionWrapper);

    private static XElement? DirectChild(XElement parent, string localName) =>
        parent.Elements().FirstOrDefault(e => e.Name.LocalName == localName);

    private static bool FormControlNamed(XElement node, string name) =>
        string.Equals(DirectChild(node, "Name")?.Value, name, StringComparison.OrdinalIgnoreCase);

    private static ToolResult<object>? LocateFormControl(
        XDocument doc, string kind, string controlName, out LocatedFormControl? located)
    {
        located = null;
        var candidates = new List<LocatedFormControl>();

        if (kind == "formextension")
        {
            foreach (var wrapper in doc.Descendants().Where(e => e.Name.LocalName == "AxFormExtensionControl"))
            {
                var formControl = DirectChild(wrapper, "FormControl");
                if (formControl is not null && FormControlNamed(formControl, controlName))
                    candidates.Add(new LocatedFormControl(formControl, wrapper, true));
            }
        }

        foreach (var control in doc.Descendants().Where(e => e.Name.LocalName == "AxFormControl"))
        {
            if (FormControlNamed(control, controlName))
                candidates.Add(new LocatedFormControl(control, control, false));
        }

        if (candidates.Count == 0)
            return ToolResult<object>.Fail("FORM_CONTROL_NOT_FOUND",
                $"Control '{controlName}' was not found.");
        if (candidates.Count != 1)
            return ToolResult<object>.Fail("FORM_CONTROL_AMBIGUOUS",
                $"Control '{controlName}' matched {candidates.Count} metadata nodes.");

        located = candidates[0];
        return null;
    }

    internal static (object? Applied, ToolResult<object>? Failure) ApplyFormControlOperationForTests(
        XDocument doc, ModifyRequest request) => ApplyFormControlOperation(doc, request);

    private static (object? Applied, ToolResult<object>? Failure) ApplyFormControlOperation(
        XDocument doc, ModifyRequest request)
    {
        var kind = (request.Kind ?? string.Empty).Trim().ToLowerInvariant();
        if (kind is not ("form" or "formextension"))
            return (null, ToolResult<object>.Fail(D365FoErrorCodes.BadInput,
                "Form-control operations require kind form or formextension."));

        var locateFailure = LocateFormControl(doc, kind, request.Member, out var target);
        if (locateFailure is not null) return (null, locateFailure);
        if (target is null)
            return (null, ToolResult<object>.Fail("FORM_CONTROL_NOT_FOUND", "Control could not be resolved."));

        if (request.Operation == Operation.SetControlProperty)
        {
            var property = (request.ControlProperty ?? string.Empty).Trim();
            if (!AllowedControlProperties.Contains(property))
                return (null, ToolResult<object>.Fail(D365FoErrorCodes.BadInput,
                    $"Unsupported form-control property '{property}'."));
            if (request.Value is null)
                return (null, ToolResult<object>.Fail(D365FoErrorCodes.BadInput, "Property value is required."));

            var existing = DirectChild(target.PropertyNode, property);
            var oldValue = existing?.Value;
            if (existing is null)
                target.PropertyNode.Add(new XElement(target.PropertyNode.Name.Namespace + property, request.Value));
            else
                existing.Value = request.Value;

            return (new { control = request.Member, property, oldValue, newValue = request.Value }, null);
        }

        if (string.IsNullOrWhiteSpace(request.Sibling))
            return (null, ToolResult<object>.Fail(D365FoErrorCodes.BadInput, "Sibling control is required."));

        if (target.ExtensionWrapper)
        {
            if (request.Operation == Operation.PlaceControlBefore)
                return (null, ToolResult<object>.Fail(D365FoErrorCodes.BadInput,
                    "Top-level form-extension controls support place-after only."));

            var position = DirectChild(target.PlacementNode, "PositionType");
            if (position is null)
            {
                position = new XElement(target.PlacementNode.Name.Namespace + "PositionType", "AfterItem");
                target.PlacementNode.Add(position);
            }
            else position.Value = "AfterItem";

            var previous = DirectChild(target.PlacementNode, "PreviousSibling");
            if (previous is null)
            {
                previous = new XElement(target.PlacementNode.Name.Namespace + "PreviousSibling", request.Sibling);
                target.PlacementNode.Add(previous);
            }
            else previous.Value = request.Sibling;

            return (new { control = request.Member, relation = "after", sibling = request.Sibling }, null);
        }

        var siblingFailure = LocateFormControl(doc, kind, request.Sibling, out var sibling);
        if (siblingFailure is not null) return (null, siblingFailure);
        if (sibling is null || sibling.ExtensionWrapper)
            return (null, ToolResult<object>.Fail("FORM_CONTROL_SIBLING_INVALID",
                "Sibling is not an inline form control."));
        if (!ReferenceEquals(target.PlacementNode.Parent, sibling.PlacementNode.Parent))
            return (null, ToolResult<object>.Fail("FORM_CONTROL_PARENT_MISMATCH",
                "Target and sibling must belong to the same Controls collection."));

        target.PlacementNode.Remove();
        if (request.Operation == Operation.PlaceControlBefore)
            sibling.PlacementNode.AddBeforeSelf(target.PlacementNode);
        else
            sibling.PlacementNode.AddAfterSelf(target.PlacementNode);

        return (new
        {
            control = request.Member,
            relation = request.Operation == Operation.PlaceControlBefore ? "before" : "after",
            sibling = request.Sibling,
        }, null);
    }

    /// <summary>Find a container control by name anywhere in the design tree; null name means the design root.</summary>
    private static XElement? FindContainer(XElement design, string? name)
'@

Replace-Exact 'src\D365FO.Core\Bridge\BatchStepParser.cs' @'
                DataField = Str(element, "dataField"),
'@ @'
                DataField = Str(element, "dataField"),
                ControlProperty = Str(element, "property"),
                Sibling = Str(element, "sibling"),
'@

$classMemberEngine = @'
﻿// <copyright file="ClassMemberModifyEngine.cs" company="d365fo-cli contributors">
// MIT
// </copyright>

using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using D365FO.Core.Guardrails;
using D365FO.Core.Index;
using D365FO.Core.Scaffolding;
using D365FO.Core.Validation;

namespace D365FO.Core.Bridge;

public static class ClassMemberModifyEngine
{
    public enum Operation
    {
        AddField,
        AddConstant,
        AddMethod,
    }

    public sealed record ModifyRequest(
        Operation Operation,
        string ClassName,
        string MemberName,
        string? Type = null,
        string? Access = null,
        string? Source = null,
        string? Model = null,
        string? Initializer = null);

    public static ToolResult<object> Modify(
        ModifyRequest request, MetadataRepository? repo, BridgeOptions? bridgeOptions = null)
    {
        var options = bridgeOptions ?? MethodModifyEngine.DefaultBridgeOptions();
        if (!BridgeClient.IsAvailable(options))
        {
            return ToolResult<object>.Fail(D365FoErrorCodes.BridgeRequired,
                "d365fo modify add-class-field/add-class-method requires D365FO.Bridge (Windows VM, IMetadataProvider-backed).",
                "Run on a D365FO VM with D365FO_BRIDGE_ENABLED=1 and D365FO_BRIDGE_PATH / D365FO_PACKAGES_PATH set. This command intentionally has no raw-XML fallback.");
        }

        using var client = new BridgeClient(options);
        return ModifyCore(request, repo, client);
    }

    internal static ToolResult<object> ModifyCore(
        ModifyRequest request, MetadataRepository? repo, BridgeClient client, string? journalDbOverride = null)
    {
        var validation = ValidateRequest(request);
        if (validation is not null) return validation;

        var model = request.Model ?? repo?.GetClassDetails(request.ClassName)?.Class.Model;
        if (string.IsNullOrWhiteSpace(model))
        {
            return ToolResult<object>.Fail(D365FoErrorCodes.ClassNotFound,
                $"Class '{request.ClassName}' was not found in the SQLite index and no --model override was supplied.",
                "Run d365fo index refresh --model <MODEL>, or pass --model <MODEL> explicitly.");
        }

        JsonObject? readResult;
        try
        {
            readResult = client.SendAsync("readObjectXml",
                new JsonObject { ["kind"] = "class", ["name"] = request.ClassName })
                .GetAwaiter().GetResult();
        }
        catch (BridgeException ex)
        {
            return ToolResult<object>.Fail(D365FoErrorCodes.BridgeRequired,
                "Bridge error while reading the class: " + ex.Message);
        }

        if (readResult is null)
            return ToolResult<object>.Fail(D365FoErrorCodes.BridgeRequired, "Bridge returned no result for readObjectXml.");
        if ((bool?)readResult["ok"] != true)
        {
            var code = (string?)readResult["error"] ?? D365FoErrorCodes.ClassNotFound;
            var message = (string?)readResult["message"] ?? "unknown error";
            return ToolResult<object>.Fail(code == "NOT_FOUND" ? D365FoErrorCodes.ClassNotFound : code,
                $"Bridge could not read class '{request.ClassName}': {message}");
        }

        var xml = (string?)readResult["xml"];
        if (string.IsNullOrWhiteSpace(xml))
            return ToolResult<object>.Fail("READ_FAILED", $"Bridge returned empty XML for class '{request.ClassName}'.");

        XDocument document;
        try { document = XDocument.Parse(xml); }
        catch (Exception ex)
        {
            return ToolResult<object>.Fail("READ_FAILED", "Could not parse class XML returned by the bridge: " + ex.Message);
        }

        var (applied, editFailure) = ApplyToDocument(document, request, repo);
        if (editFailure is not null) return editFailure;

        ContractOrderCanonicalizer.Apply(document);
        var newXml = document.ToString(SaveOptions.DisableFormatting);

        ObjectModifyEngine.RecordJournalEntry(
            new ObjectModifyEngine.WriteTarget("class", request.ClassName, model!, IsExtension: false, Exists: true),
            xml,
            request.Operation == Operation.AddField
                ? $"modify add-class-field {request.ClassName} {request.MemberName}"
                : request.Operation == Operation.AddConstant
                    ? $"modify add-class-constant {request.ClassName} {request.MemberName}"
                    : $"modify add-class-method {request.ClassName} {request.MemberName}",
            journalDbOverride);

        JsonObject? writeResult;
        try
        {
            writeResult = client.SendAsync("updateObject", new JsonObject
            {
                ["kind"] = "class",
                ["name"] = request.ClassName,
                ["model"] = model,
                ["xml"] = newXml,
            }).GetAwaiter().GetResult();
        }
        catch (BridgeException ex)
        {
            return ToolResult<object>.Fail(D365FoErrorCodes.WriteFailed,
                "Bridge error while writing the class: " + ex.Message);
        }

        if (writeResult is null)
            return ToolResult<object>.Fail(D365FoErrorCodes.WriteFailed, "Bridge returned no result for updateObject.");
        if ((bool?)writeResult["ok"] != true)
        {
            var code = (string?)writeResult["error"] ?? D365FoErrorCodes.WriteFailed;
            var message = (string?)writeResult["message"] ?? "unknown error";
            return ToolResult<object>.Fail(code, $"Bridge could not update class '{request.ClassName}': {message}");
        }

        var verifyFailure = VerifyReadBack(client, request);
        if (verifyFailure is not null) return verifyFailure;

        return ToolResult<object>.Success(new
        {
            operation = request.Operation.ToString(),
            kind = "class",
            name = request.ClassName,
            member = request.MemberName,
            model,
            source = "bridge",
            applied,
        }, [$"Index not auto-refreshed — run d365fo index refresh --model {model} so the new member is searchable."]);
    }

    internal static (object? Applied, ToolResult<object>? Failure) ApplyToDocument(
        XDocument document, ModifyRequest request, MetadataRepository? repo = null)
    {
        if (document.Root is null || document.Root.Name.LocalName != "AxClass")
            return (null, ToolResult<object>.Fail(D365FoErrorCodes.BadInput, "Expected an AxClass document."));

        return request.Operation switch
        {
            Operation.AddField => ApplyField(document, request),
            Operation.AddConstant => ApplyConstant(document, request),
            Operation.AddMethod => ApplyMethod(document, request, repo),
            _ => (null, ToolResult<object>.Fail(D365FoErrorCodes.BadInput, "Unsupported class-member operation.")),
        };
    }

    private static (object? Applied, ToolResult<object>? Failure) ApplyField(
        XDocument document, ModifyRequest request)
    {
        var sourceCode = document.Root!.Elements().FirstOrDefault(e => e.Name.LocalName == "SourceCode");
        var declaration = sourceCode?.Elements().FirstOrDefault(e => e.Name.LocalName == "Declaration");
        if (declaration is null)
        {
            return (null, ToolResult<object>.Fail("CLASS_DECLARATION_NOT_FOUND",
                $"Class '{request.ClassName}' has no SourceCode/Declaration node."));
        }

        var text = declaration.Value;
        var duplicatePattern = $@"(?m)^\s*(?:private|protected|public)?\s*(?:static\s+)?[A-Za-z_][A-Za-z0-9_]*\s+{Regex.Escape(request.MemberName)}\s*(?:;|=)";
        if (Regex.IsMatch(text, duplicatePattern, RegexOptions.CultureInvariant))
        {
            return (null, ToolResult<object>.Fail(D365FoErrorCodes.AlreadyExists,
                $"Field '{request.MemberName}' already exists on class '{request.ClassName}'."));
        }

        var closingBrace = text.LastIndexOf('}');
        if (closingBrace < 0)
        {
            return (null, ToolResult<object>.Fail("CLASS_DECLARATION_INVALID",
                $"Class '{request.ClassName}' declaration has no closing brace."));
        }

        var newline = text.Contains("\r\n", StringComparison.Ordinal) ? "\r\n" : "\n";
        var access = string.IsNullOrWhiteSpace(request.Access) ? "protected" : request.Access!.Trim().ToLowerInvariant();
        var line = $"    {access} {request.Type!.Trim()} {request.MemberName};";
        var prefix = text[..closingBrace].TrimEnd('\r','\n');
        var suffix = text[closingBrace..];
        declaration.ReplaceAll(new XCData(prefix + newline + line + newline + suffix));

        return (new { field = request.MemberName, type = request.Type, access }, null);
    }

    private static (object? Applied, ToolResult<object>? Failure) ApplyConstant(
        XDocument document, ModifyRequest request)
    {
        var sourceCode = document.Root!.Elements().FirstOrDefault(e => e.Name.LocalName == "SourceCode");
        var declaration = sourceCode?.Elements().FirstOrDefault(e => e.Name.LocalName == "Declaration");
        if (declaration is null)
        {
            return (null, ToolResult<object>.Fail("CLASS_DECLARATION_NOT_FOUND",
                $"Class '{request.ClassName}' has no SourceCode/Declaration node."));
        }

        var text = declaration.Value;
        var duplicatePattern = $@"(?m)^\s*(?:private|protected|public)?\s*(?:static\s+)?const\s+[A-Za-z_][A-Za-z0-9_]*\s+{Regex.Escape(request.MemberName)}\s*=";
        if (Regex.IsMatch(text, duplicatePattern, RegexOptions.CultureInvariant))
        {
            return (null, ToolResult<object>.Fail(D365FoErrorCodes.AlreadyExists,
                $"Constant '{request.MemberName}' already exists on class '{request.ClassName}'."));
        }

        var closingBrace = text.LastIndexOf('}');
        if (closingBrace < 0)
        {
            return (null, ToolResult<object>.Fail("CLASS_DECLARATION_INVALID",
                $"Class '{request.ClassName}' declaration has no closing brace."));
        }

        var newline = text.Contains("\r\n", StringComparison.Ordinal) ? "\r\n" : "\n";
        var access = string.IsNullOrWhiteSpace(request.Access) ? "private" : request.Access!.Trim().ToLowerInvariant();
        var line = $"    {access} const {request.Type!.Trim()} {request.MemberName} = {request.Initializer!.Trim()};";
        var prefix = text[..closingBrace].TrimEnd('\r','\n');
        var suffix = text[closingBrace..];
        declaration.ReplaceAll(new XCData(prefix + newline + line + newline + suffix));

        return (new { constant = request.MemberName, type = request.Type, access, initializer = request.Initializer }, null);
    }

    private static string NormalizeNewlines(string source) =>
        source.Replace("\r\n", "\n", StringComparison.Ordinal)
              .Replace("\r", "\n", StringComparison.Ordinal);

    private static string CanonicalSourceForComparison(string source) =>
        NormalizeNewlines(source).TrimEnd('\n');

    private static bool HasCanonicalXmlSummary(string source) =>
        Regex.IsMatch(source, @"(?m)^    ///\s*<summary>", RegexOptions.CultureInvariant);

    private static ToolResult<object>? ValidateMethodSourceQuality(
        string source, string methodName)
    {
        var normalized = NormalizeNewlines(source);

        if (!normalized.Contains('\n'))
            return ToolResult<object>.Fail("XPP_SOURCE_QUALITY_FAILED",
                $"New method '{methodName}' must use canonical structured multiline X++ source.");

        if (normalized.Contains('\t'))
            return ToolResult<object>.Fail("XPP_SOURCE_QUALITY_FAILED",
                $"New method '{methodName}' must use spaces, not tabs, for canonical indentation.");

        if (!HasCanonicalXmlSummary(normalized))
            return ToolResult<object>.Fail("XPP_SOURCE_QUALITY_FAILED",
                $"New method '{methodName}' must include canonical XML summary documentation.");

        var firstNonBlank = normalized.Split('\n').FirstOrDefault(line => !string.IsNullOrWhiteSpace(line)) ?? string.Empty;
        if (!firstNonBlank.StartsWith("    ", StringComparison.Ordinal) ||
            firstNonBlank.StartsWith("     ", StringComparison.Ordinal))
            return ToolResult<object>.Fail("XPP_SOURCE_QUALITY_FAILED",
                $"New method '{methodName}' must use canonical four-space member indentation.");

        if (!Regex.IsMatch(normalized, @"(?m)^    \{$", RegexOptions.CultureInvariant))
            return ToolResult<object>.Fail("XPP_SOURCE_QUALITY_FAILED",
                $"New method '{methodName}' must place the opening method brace on its own canonically indented line.");

        return null;
    }

    private static (object? Applied, ToolResult<object>? Failure) ApplyMethod(
        XDocument document, ModifyRequest request, MetadataRepository? repo)
    {
        var source = request.Source!.TrimEnd('\r', '\n');
        if (!Regex.IsMatch(source, $@"\b{Regex.Escape(request.MemberName)}\s*\(",
                RegexOptions.CultureInvariant))
        {
            return (null, ToolResult<object>.Fail(D365FoErrorCodes.BadInput,
                $"--source does not declare method '{request.MemberName}'."));
        }

        if (repo is not null)
        {
            var violations = new List<string>();
            try
            {
                foreach (var v in ReferenceResolver.Resolve(source, repo).Violations)
                    if (v.Severity == "error")
                        violations.Add($"[{v.Kind}] line {v.Line}: {v.Identifier} — {v.Detail}");

                var stats = repo.HasPropertyStats() ? repo : (IPropertyStatsProvider?)null;
                foreach (var v in XppValidator.Validate(source, XppValidator.CodeTypeXpp, stats))
                    if (v.Severity == "error")
                        violations.Add($"[{v.Rule}] line {v.Line}: {v.Excerpt} — {v.Fix}");
            }
            catch (Exception ex)
            {
                return (null, ToolResult<object>.Fail(D365FoErrorCodes.ValidationFailed,
                    "Class-method validation could not complete: " + ex.Message));
            }

            if (violations.Count > 0)
            {
                return (null, ToolResult<object>.Fail(D365FoErrorCodes.ValidationFailed,
                    $"New method '{request.MemberName}' failed validation:\n" + string.Join("\n", violations)));
            }
        }

        var sourceCode = document.Root!.Elements().FirstOrDefault(e => e.Name.LocalName == "SourceCode");
        if (sourceCode is null)
        {
            return (null, ToolResult<object>.Fail("CLASS_SOURCE_NOT_FOUND",
                $"Class '{request.ClassName}' has no SourceCode node."));
        }

        var methods = MethodModifyEngine.LocateMethodsContainer(document.Root);
        if (methods is null)
        {
            methods = new XElement(sourceCode.Name.Namespace + "Methods");
            sourceCode.Add(methods);
        }

        var existing = methods.Elements()
            .FirstOrDefault(e => e.Name.LocalName == "Method" &&
                string.Equals(e.Elements().FirstOrDefault(x => x.Name.LocalName == "Name")?.Value,
                    request.MemberName, StringComparison.OrdinalIgnoreCase));
        if (existing is not null)
        {
            return (null, ToolResult<object>.Fail(D365FoErrorCodes.AlreadyExists,
                $"Method '{request.MemberName}' already exists on class '{request.ClassName}'.",
                "Use d365fo modify method to replace the body of an existing method."));
        }

        var qualityFailure = ValidateMethodSourceQuality(source, request.MemberName);
        if (qualityFailure is not null) return (null, qualityFailure);

        methods.Add(new XElement(methods.Name.Namespace + "Method",
            new XElement(methods.Name.Namespace + "Name", request.MemberName),
            new XElement(methods.Name.Namespace + "Source", new XCData(source))));

        return (new { method = request.MemberName }, null);
    }

    private static ToolResult<object>? VerifyReadBack(BridgeClient client, ModifyRequest request)
    {
        JsonObject? readBack;
        try
        {
            readBack = client.SendAsync("readObjectXml",
                new JsonObject { ["kind"] = "class", ["name"] = request.ClassName })
                .GetAwaiter().GetResult();
        }
        catch (BridgeException ex)
        {
            return ToolResult<object>.Fail("WRITE_VERIFY_FAILED",
                "Write completed but semantic read-back failed: " + ex.Message);
        }

        var xml = (string?)readBack?["xml"];
        if ((bool?)readBack?["ok"] != true || string.IsNullOrWhiteSpace(xml))
            return ToolResult<object>.Fail("WRITE_VERIFY_FAILED",
                "Write completed but the bridge could not read the class back.");

        XDocument document;
        try { document = XDocument.Parse(xml); }
        catch (Exception ex)
        {
            return ToolResult<object>.Fail("WRITE_VERIFY_FAILED",
                "Write completed but read-back XML could not be parsed: " + ex.Message);
        }

        if (request.Operation == Operation.AddField || request.Operation == Operation.AddConstant)
        {
            var declaration = document.Root?.Elements().FirstOrDefault(e => e.Name.LocalName == "SourceCode")
                ?.Elements().FirstOrDefault(e => e.Name.LocalName == "Declaration")?.Value ?? string.Empty;
            var memberPattern = request.Operation == Operation.AddConstant
                ? $@"(?m)^\s*(?:private|protected|public)?\s*(?:static\s+)?const\s+[A-Za-z_][A-Za-z0-9_]*\s+{Regex.Escape(request.MemberName)}\s*="
                : $@"(?m)^\s*(?:private|protected|public)?\s*(?:static\s+)?[A-Za-z_][A-Za-z0-9_]*\s+{Regex.Escape(request.MemberName)}\s*(?:;|=)";
            if (!Regex.IsMatch(declaration, memberPattern, RegexOptions.CultureInvariant))
                return ToolResult<object>.Fail("WRITE_VERIFY_FAILED",
                    $"Write completed but member '{request.MemberName}' is absent on read-back.");
        }
        else
        {
            var methods = MethodModifyEngine.LocateMethodsContainer(document.Root);
            var method = methods?.Elements().FirstOrDefault(e => e.Name.LocalName == "Method" &&
                string.Equals(e.Elements().FirstOrDefault(x => x.Name.LocalName == "Name")?.Value,
                    request.MemberName, StringComparison.OrdinalIgnoreCase));
            if (method is null)
                return ToolResult<object>.Fail("WRITE_VERIFY_FAILED",
                    $"Write completed but method '{request.MemberName}' is absent on read-back.");

            var actualSource = method.Elements().FirstOrDefault(e => e.Name.LocalName == "Source")?.Value ?? string.Empty;
            var expectedSource = request.Source!.TrimEnd('\r', '\n');
            if (!string.Equals(CanonicalSourceForComparison(actualSource), CanonicalSourceForComparison(expectedSource), StringComparison.Ordinal))
                return ToolResult<object>.Fail("WRITE_VERIFY_FAILED",
                    $"Write completed but persisted source for method '{request.MemberName}' differs from the submitted canonical source.");
        }

        return null;
    }

    private static ToolResult<object>? ValidateRequest(ModifyRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.ClassName))
            return ToolResult<object>.Fail(D365FoErrorCodes.BadInput, "Class name is required.");
        if (string.IsNullOrWhiteSpace(request.MemberName))
            return ToolResult<object>.Fail(D365FoErrorCodes.BadInput, "Member name is required.");

        return request.Operation switch
        {
            Operation.AddField when string.IsNullOrWhiteSpace(request.Type) =>
                ToolResult<object>.Fail(D365FoErrorCodes.BadInput, "--type is required for modify add-class-field."),
            Operation.AddField when !Regex.IsMatch(request.Type!, @"^[A-Za-z_][A-Za-z0-9_]*$") =>
                ToolResult<object>.Fail(D365FoErrorCodes.BadInput, "--type must be an X++ primitive/type/EDT identifier."),
            Operation.AddField when !string.IsNullOrWhiteSpace(request.Access) &&
                !string.Equals(request.Access, "private", StringComparison.OrdinalIgnoreCase) &&
                !string.Equals(request.Access, "protected", StringComparison.OrdinalIgnoreCase) =>
                ToolResult<object>.Fail(D365FoErrorCodes.BadInput,
                    "--access must be private or protected. Public instance fields are intentionally not supported."),
            Operation.AddConstant when string.IsNullOrWhiteSpace(request.Type) =>
                ToolResult<object>.Fail(D365FoErrorCodes.BadInput, "--type is required for modify add-class-constant."),
            Operation.AddConstant when string.IsNullOrWhiteSpace(request.Initializer) =>
                ToolResult<object>.Fail(D365FoErrorCodes.BadInput, "--initializer is required for modify add-class-constant."),
            Operation.AddConstant when !string.IsNullOrWhiteSpace(request.Access) &&
                !string.Equals(request.Access, "private", StringComparison.OrdinalIgnoreCase) &&
                !string.Equals(request.Access, "protected", StringComparison.OrdinalIgnoreCase) =>
                ToolResult<object>.Fail(D365FoErrorCodes.BadInput, "--access must be private or protected for class constants."),
            Operation.AddMethod when string.IsNullOrWhiteSpace(request.Source) =>
                ToolResult<object>.Fail(D365FoErrorCodes.BadInput,
                    "--source is required for modify add-class-method and must contain the full X++ method declaration."),
            _ => null,
        };
    }
}
'@

$classMemberCommands = @'
using D365FO.Core;
using D365FO.Core.Bridge;
using D365FO.Core.Index;
using Spectre.Console.Cli;

namespace D365FO.Cli.Commands.Modify;

public sealed class ModifyAddClassFieldCommand : Command<ModifyAddClassFieldCommand.Settings>
{
    public sealed class Settings : D365OutputSettings
    {
        [CommandArgument(0, "<CLASS>")]
        public string ClassName { get; init; } = "";

        [CommandArgument(1, "<FIELD>")]
        public string Field { get; init; } = "";

        [CommandOption("--type <TYPE>")]
        public string? Type { get; init; }

        [CommandOption("--access <ACCESS>")]
        public string? Access { get; init; }

        [CommandOption("--model <MODEL>")]
        public string? Model { get; init; }
    }

    public override int Execute(CommandContext context, Settings settings)
    {
        MetadataRepository? repo = null;
        try { repo = RepoFactory.Create(); } catch { }
        return RenderHelpers.Render(OutputMode.Resolve(settings.Output),
            ClassMemberModifyEngine.Modify(new ClassMemberModifyEngine.ModifyRequest(
                ClassMemberModifyEngine.Operation.AddField,
                settings.ClassName, settings.Field, settings.Type, settings.Access, Model: settings.Model), repo));
    }
}

public sealed class ModifyAddClassConstantCommand : Command<ModifyAddClassConstantCommand.Settings>
{
    public sealed class Settings : D365OutputSettings
    {
        [CommandArgument(0, "<CLASS>")] public string ClassName { get; init; } = "";
        [CommandArgument(1, "<CONSTANT>")] public string Constant { get; init; } = "";
        [CommandOption("--type <TYPE>")] public string? Type { get; init; }
        [CommandOption("--initializer <XPP>")] public string? Initializer { get; init; }
        [CommandOption("--access <ACCESS>")] public string? Access { get; init; }
        [CommandOption("--model <MODEL>")] public string? Model { get; init; }
    }

    public override int Execute(CommandContext context, Settings settings)
    {
        MetadataRepository? repo = null;
        try { repo = RepoFactory.Create(); } catch { }
        return RenderHelpers.Render(OutputMode.Resolve(settings.Output),
            ClassMemberModifyEngine.Modify(new ClassMemberModifyEngine.ModifyRequest(
                ClassMemberModifyEngine.Operation.AddConstant,
                settings.ClassName, settings.Constant, settings.Type, settings.Access,
                Model: settings.Model, Initializer: settings.Initializer), repo));
    }
}

public sealed class ModifyAddClassMethodCommand : Command<ModifyAddClassMethodCommand.Settings>
{
    public sealed class Settings : D365OutputSettings
    {
        [CommandArgument(0, "<CLASS>")]
        public string ClassName { get; init; } = "";

        [CommandArgument(1, "<METHOD>")]
        public string Method { get; init; } = "";

        [CommandOption("--source <XPP>")]
        public string? Source { get; init; }

        [CommandOption("--model <MODEL>")]
        public string? Model { get; init; }
    }

    public override int Execute(CommandContext context, Settings settings)
    {
        MetadataRepository? repo = null;
        try { repo = RepoFactory.Create(); } catch { }
        return RenderHelpers.Render(OutputMode.Resolve(settings.Output),
            ClassMemberModifyEngine.Modify(new ClassMemberModifyEngine.ModifyRequest(
                ClassMemberModifyEngine.Operation.AddMethod,
                settings.ClassName, settings.Method, Source: settings.Source, Model: settings.Model), repo));
    }
}
'@

$mcpHandlers = @'
using D365FO.Core;
using D365FO.Core.Bridge;

namespace D365FO.Mcp;

public sealed partial class ToolHandlers
{
    public ToolResult<object> ModifyClassMember(
        string action, string className, string member,
        string? type = null, string? access = null, string? source = null, string? model = null, string? initializer = null)
    {
        var operation = (action ?? string.Empty).Trim().ToLowerInvariant() switch
        {
            "add-field" => ClassMemberModifyEngine.Operation.AddField,
            "add-constant" => ClassMemberModifyEngine.Operation.AddConstant,
            "add-method" => ClassMemberModifyEngine.Operation.AddMethod,
            _ => (ClassMemberModifyEngine.Operation?)null,
        };

        if (operation is null)
            return ToolResult<object>.Fail(D365FoErrorCodes.BadInput,
                $"Unknown class-member action '{action}'.", "Use add-field, add-constant or add-method.");

        return ClassMemberModifyEngine.Modify(new ClassMemberModifyEngine.ModifyRequest(
            operation.Value, className, member, type, access, source, model, initializer), _repo);
    }
}
'@

$coreTests = @'
using System.Xml.Linq;
using D365FO.Core.Bridge;
using Xunit;

namespace D365FO.Core.Tests;

public sealed class ClassMemberModifyEngineTests
{
    private const string ClassXml =
        "<AxClass><Name>Fixture</Name><SourceCode>" +
        "<Declaration><![CDATA[public class Fixture\n{\n}]]></Declaration>" +
        "<Methods /></SourceCode></AxClass>";

    [Fact]
    public void Add_field_updates_only_the_class_declaration()
    {
        var doc = XDocument.Parse(ClassXml);
        var (applied, failure) = ClassMemberModifyEngine.ApplyToDocument(doc,
            new ClassMemberModifyEngine.ModifyRequest(
                ClassMemberModifyEngine.Operation.AddField,
                "Fixture", "payerAccount", "CustAccount", "protected"));

        Assert.Null(failure);
        Assert.NotNull(applied);
        var declaration = doc.Root!.Element("SourceCode")!.Element("Declaration")!.Value;
        Assert.Contains("protected CustAccount payerAccount;", declaration);
        Assert.Empty(doc.Root.Element("SourceCode")!.Element("Methods")!.Elements("Method"));
    }

    [Fact]
    public void Add_field_refuses_a_duplicate()
    {
        var doc = XDocument.Parse(ClassXml.Replace("}", "    protected CustAccount payerAccount;\n}"));
        var (_, failure) = ClassMemberModifyEngine.ApplyToDocument(doc,
            new ClassMemberModifyEngine.ModifyRequest(
                ClassMemberModifyEngine.Operation.AddField,
                "Fixture", "payerAccount", "CustAccount", "protected"));

        Assert.NotNull(failure);
        Assert.False(failure!.Ok);
        Assert.Equal(D365FoErrorCodes.AlreadyExists, failure.Error!.Code);
    }

    [Fact]
    public void Add_constant_updates_only_the_class_declaration()
    {
        var doc = XDocument.Parse(ClassXml);
        var (applied, failure) = ClassMemberModifyEngine.ApplyToDocument(doc,
            new ClassMemberModifyEngine.ModifyRequest(
                ClassMemberModifyEngine.Operation.AddConstant,
                "Fixture", "DataSourceName", "str", "private",
                Model: "FixtureModel", Initializer: "'Alias'"));

        Assert.Null(failure);
        Assert.NotNull(applied);
        var declaration = doc.Root!.Element("SourceCode")!.Element("Declaration")!.Value;
        Assert.Contains("private const str DataSourceName = 'Alias';", declaration);
    }

    [Fact]
    public void Add_method_appends_a_structured_method_node_and_preserves_source_exactly()
    {
        var doc = XDocument.Parse(ClassXml);
        const string source =
            "    /// <summary>\n" +
            "    /// Returns the payer account.\n" +
            "    /// </summary>\n" +
            "    public CustAccount payerAccount()\n" +
            "    {\n" +
            "        return payerAccount;\n" +
            "    }";
        var (applied, failure) = ClassMemberModifyEngine.ApplyToDocument(doc,
            new ClassMemberModifyEngine.ModifyRequest(
                ClassMemberModifyEngine.Operation.AddMethod,
                "Fixture", "payerAccount", Source: source));

        Assert.Null(failure);
        Assert.NotNull(applied);
        var method = Assert.Single(doc.Root!.Element("SourceCode")!.Element("Methods")!.Elements("Method"));
        Assert.Equal("payerAccount", method.Element("Name")!.Value);
        Assert.Equal(source, method.Element("Source")!.Value);
    }

    [Fact]
    public void Add_method_rejects_noncanonical_source_even_without_neighbors()
    {
        var doc = XDocument.Parse(ClassXml);

        var (_, compact) = ClassMemberModifyEngine.ApplyToDocument(doc,
            new ClassMemberModifyEngine.ModifyRequest(
                ClassMemberModifyEngine.Operation.AddMethod,
                "Fixture", "payerAccount", Source: "public CustAccount payerAccount(){ return payerAccount; }"));
        Assert.NotNull(compact);
        Assert.Equal("XPP_SOURCE_QUALITY_FAILED", compact!.Error!.Code);

        var (_, missingDocs) = ClassMemberModifyEngine.ApplyToDocument(doc,
            new ClassMemberModifyEngine.ModifyRequest(
                ClassMemberModifyEngine.Operation.AddMethod,
                "Fixture", "payerAccount",
                Source: "    public CustAccount payerAccount()\n    {\n        return '';\n    }"));
        Assert.NotNull(missingDocs);
        Assert.Equal("XPP_SOURCE_QUALITY_FAILED", missingDocs!.Error!.Code);

        var (_, badIndent) = ClassMemberModifyEngine.ApplyToDocument(doc,
            new ClassMemberModifyEngine.ModifyRequest(
                ClassMemberModifyEngine.Operation.AddMethod,
                "Fixture", "payerAccount",
                Source: "/// <summary>\n/// Payer account.\n/// </summary>\npublic CustAccount payerAccount()\n{\n    return '';\n}"));
        Assert.NotNull(badIndent);
        Assert.Equal("XPP_SOURCE_QUALITY_FAILED", badIndent!.Error!.Code);
    }

    [Fact]
    public void Add_method_uses_canonical_style_even_when_neighbor_is_legacy()
    {
        var doc = XDocument.Parse(
            "<AxClass><Name>Fixture</Name><SourceCode><Declaration><![CDATA[public class Fixture\n{\n}]]></Declaration>" +
            "<Methods><Method><Name>legacy</Name><Source><![CDATA[public void legacy(){ }]]></Source></Method></Methods>" +
            "</SourceCode></AxClass>");
        const string source =
            "    /// <summary>\n" +
            "    /// Returns the payer account.\n" +
            "    /// </summary>\n" +
            "    public CustAccount payerAccount()\n" +
            "    {\n" +
            "        return payerAccount;\n" +
            "    }";

        var (_, failure) = ClassMemberModifyEngine.ApplyToDocument(doc,
            new ClassMemberModifyEngine.ModifyRequest(
                ClassMemberModifyEngine.Operation.AddMethod,
                "Fixture", "payerAccount", Source: source));

        Assert.Null(failure);
    }

    [Fact]
    public void Add_method_refuses_a_duplicate()
    {
        var doc = XDocument.Parse(
            "<AxClass><Name>Fixture</Name><SourceCode><Declaration><![CDATA[public class Fixture\n{\n}]]></Declaration>" +
            "<Methods><Method><Name>payerAccount</Name><Source><![CDATA[public void payerAccount()\n{\n}]]></Source></Method></Methods>" +
            "</SourceCode></AxClass>");
        var (_, failure) = ClassMemberModifyEngine.ApplyToDocument(doc,
            new ClassMemberModifyEngine.ModifyRequest(
                ClassMemberModifyEngine.Operation.AddMethod,
                "Fixture", "payerAccount", Source: "public void payerAccount()\n{\n}"));

        Assert.NotNull(failure);
        Assert.False(failure!.Ok);
        Assert.Equal(D365FoErrorCodes.AlreadyExists, failure.Error!.Code);
    }
}
'@

Add-OverlayFile 'src\D365FO.Core\Bridge\ClassMemberModifyEngine.cs' $classMemberEngine
Add-OverlayFile 'src\D365FO.Cli\Commands\Modify\ModifyClassMemberCommands.cs' $classMemberCommands
Add-OverlayFile 'src\D365FO.Mcp\ToolHandlers.ClassMembers.cs' $mcpHandlers
Add-OverlayFile 'tests\D365FO.Core.Tests\ClassMemberModifyEngineTests.cs' $coreTests

$formMethodEngine = @'
using System.Text.Json.Nodes;
using System.Xml.Linq;
using D365FO.Core.Guardrails;
using D365FO.Core.Index;
using D365FO.Core.Scaffolding;

namespace D365FO.Core.Bridge;

public static class FormMethodModifyEngine
{
    public enum Operation { AddFormMethod, AddControlMethod }

    public sealed record ModifyRequest(
        Operation Operation,
        string FormName,
        string MethodName,
        string Source,
        string? ControlName = null,
        string? Model = null);

    public static ToolResult<object> Modify(
        ModifyRequest request, MetadataRepository? repo, BridgeOptions? bridgeOptions = null)
    {
        var options = bridgeOptions ?? MethodModifyEngine.DefaultBridgeOptions();
        if (!BridgeClient.IsAvailable(options))
            return ToolResult<object>.Fail(D365FoErrorCodes.BridgeRequired,
                "Form method mutation requires D365FO.Bridge.");

        using var client = new BridgeClient(options);
        return ModifyCore(request, repo, client);
    }

    private static string NormalizeNewlines(string source) =>
        source.Replace("\r\n", "\n", StringComparison.Ordinal)
              .Replace("\r", "\n", StringComparison.Ordinal);

    private static string CanonicalSourceForComparison(string source) =>
        NormalizeNewlines(source).TrimEnd('\n');

    private static bool HasCanonicalXmlSummary(string source) =>
        source.Contains("    /// <summary>", StringComparison.Ordinal);

    private static ToolResult<object>? ValidateMethodSourceQuality(
        string source, string methodName)
    {
        var normalized = NormalizeNewlines(source);

        if (!normalized.Contains('\n'))
            return ToolResult<object>.Fail("XPP_SOURCE_QUALITY_FAILED",
                $"New form method '{methodName}' must use canonical structured multiline X++ source.");

        if (normalized.Contains('\t'))
            return ToolResult<object>.Fail("XPP_SOURCE_QUALITY_FAILED",
                $"New form method '{methodName}' must use spaces, not tabs, for canonical indentation.");

        if (!HasCanonicalXmlSummary(normalized))
            return ToolResult<object>.Fail("XPP_SOURCE_QUALITY_FAILED",
                $"New form method '{methodName}' must include canonical XML summary documentation.");

        var firstNonBlank = normalized.Split('\n').FirstOrDefault(line => !string.IsNullOrWhiteSpace(line)) ?? string.Empty;
        if (!firstNonBlank.StartsWith("    ", StringComparison.Ordinal) ||
            firstNonBlank.StartsWith("     ", StringComparison.Ordinal))
            return ToolResult<object>.Fail("XPP_SOURCE_QUALITY_FAILED",
                $"New form method '{methodName}' must use canonical four-space member indentation.");

        if (!normalized.Split('\n').Any(line => string.Equals(line, "    {", StringComparison.Ordinal)))
            return ToolResult<object>.Fail("XPP_SOURCE_QUALITY_FAILED",
                $"New form method '{methodName}' must place the opening method brace on its own canonically indented line.");

        return null;
    }

    internal static ToolResult<object>? ApplyToDocument(XDocument doc, ModifyRequest request)
    {
        var sourceCode = doc.Root?.Elements().FirstOrDefault(e => e.Name.LocalName == "SourceCode");
        if (sourceCode is null)
            return ToolResult<object>.Fail("FORM_SOURCE_NOT_FOUND", $"Form '{request.FormName}' has no SourceCode node.");

        XElement? methods;
        if (request.Operation == Operation.AddFormMethod)
        {
            methods = sourceCode.Elements().FirstOrDefault(e => e.Name.LocalName == "Methods");
            if (methods is null)
            {
                methods = new XElement(sourceCode.Name.Namespace + "Methods");
                sourceCode.AddFirst(methods);
            }
        }
        else
        {
            var dataControls = sourceCode.Elements().FirstOrDefault(e => e.Name.LocalName == "DataControls");
            var control = dataControls?.Elements().FirstOrDefault(e =>
                e.Name.LocalName == "Control" &&
                string.Equals(e.Elements().FirstOrDefault(x => x.Name.LocalName == "Name")?.Value,
                    request.ControlName, StringComparison.OrdinalIgnoreCase));
            if (control is null)
                return ToolResult<object>.Fail("FORM_CONTROL_NOT_FOUND",
                    $"Control '{request.ControlName}' was not found in form '{request.FormName}'.");
            methods = control.Elements().FirstOrDefault(e => e.Name.LocalName == "Methods");
            if (methods is null)
            {
                methods = new XElement(control.Name.Namespace + "Methods");
                control.Add(methods);
            }
        }

        if (methods.Elements().Any(e =>
            e.Name.LocalName == "Method" &&
            string.Equals(e.Elements().FirstOrDefault(x => x.Name.LocalName == "Name")?.Value,
                request.MethodName, StringComparison.OrdinalIgnoreCase)))
            return ToolResult<object>.Fail(D365FoErrorCodes.AlreadyExists,
                $"Method '{request.MethodName}' already exists at the requested form location.");

        var qualityFailure = ValidateMethodSourceQuality(request.Source, request.MethodName);
        if (qualityFailure is not null) return qualityFailure;

        methods.Add(new XElement(methods.Name.Namespace + "Method",
            new XElement(methods.Name.Namespace + "Name", request.MethodName),
            new XElement(methods.Name.Namespace + "Source", new XCData(request.Source))));
        return null;
    }

    internal static ToolResult<object> ModifyCore(
        ModifyRequest request, MetadataRepository? repo, BridgeClient client, string? journalDbOverride = null)
    {
        if (string.IsNullOrWhiteSpace(request.FormName) ||
            string.IsNullOrWhiteSpace(request.MethodName) ||
            string.IsNullOrWhiteSpace(request.Source))
            return ToolResult<object>.Fail(D365FoErrorCodes.BadInput, "Form, method and full X++ source are required.");
        if (!request.Source.Contains(request.MethodName + "(", StringComparison.Ordinal))
            return ToolResult<object>.Fail(D365FoErrorCodes.BadInput,
                $"--source does not declare method '{request.MethodName}'.");
        if (request.Operation == Operation.AddControlMethod && string.IsNullOrWhiteSpace(request.ControlName))
            return ToolResult<object>.Fail(D365FoErrorCodes.BadInput, "Control name is required.");

        var model = request.Model;
        if (string.IsNullOrWhiteSpace(model))
            return ToolResult<object>.Fail(D365FoErrorCodes.BadInput,
                "--model is required for form method mutation.");

        JsonObject? read = client.SendAsync("readObjectXml",
            new JsonObject { ["kind"] = "form", ["name"] = request.FormName }).GetAwaiter().GetResult();
        if ((bool?)read?["ok"] != true || string.IsNullOrWhiteSpace((string?)read?["xml"]))
            return ToolResult<object>.Fail("READ_FAILED", $"Bridge could not read form '{request.FormName}'.");

        var before = (string)read!["xml"]!;
        XDocument doc;
        try { doc = XDocument.Parse(before); }
        catch (Exception ex) { return ToolResult<object>.Fail("READ_FAILED", ex.Message); }

        var applyFailure = ApplyToDocument(doc, request);
        if (applyFailure is not null) return applyFailure;

        ContractOrderCanonicalizer.Apply(doc);
        var after = doc.ToString(SaveOptions.DisableFormatting);
        ObjectModifyEngine.RecordJournalEntry(
            new ObjectModifyEngine.WriteTarget("form", request.FormName, model!, IsExtension: false, Exists: true),
            before,
            request.Operation == Operation.AddFormMethod
                ? $"modify add-form-method {request.FormName} {request.MethodName}"
                : $"modify add-control-method {request.FormName} {request.ControlName} {request.MethodName}",
            journalDbOverride);

        JsonObject? write = client.SendAsync("updateObject", new JsonObject
        {
            ["kind"] = "form", ["name"] = request.FormName, ["model"] = model, ["xml"] = after,
        }).GetAwaiter().GetResult();
        if ((bool?)write?["ok"] != true)
            return ToolResult<object>.Fail(D365FoErrorCodes.WriteFailed,
                (string?)write?["message"] ?? "Bridge form update failed.");

        JsonObject? verify = client.SendAsync("readObjectXml",
            new JsonObject { ["kind"] = "form", ["name"] = request.FormName }).GetAwaiter().GetResult();
        var verifyXml = (string?)verify?["xml"];
        if ((bool?)verify?["ok"] != true || string.IsNullOrWhiteSpace(verifyXml))
            return ToolResult<object>.Fail("WRITE_VERIFY_FAILED", "Form write completed but read-back failed.");
        var verifyDoc = XDocument.Parse(verifyXml);
        var verifySource = verifyDoc.Root?.Elements().FirstOrDefault(e => e.Name.LocalName == "SourceCode");
        XElement? method;
        if (request.Operation == Operation.AddFormMethod)
        {
            method = verifySource?.Elements().FirstOrDefault(e => e.Name.LocalName == "Methods")
                ?.Elements().FirstOrDefault(e => e.Name.LocalName == "Method" &&
                    string.Equals(e.Elements().FirstOrDefault(x => x.Name.LocalName == "Name")?.Value,
                        request.MethodName, StringComparison.OrdinalIgnoreCase));
        }
        else
        {
            var dataControls = verifySource?.Elements().FirstOrDefault(e => e.Name.LocalName == "DataControls");
            var control = dataControls?.Elements().FirstOrDefault(e =>
                e.Name.LocalName == "Control" &&
                string.Equals(e.Elements().FirstOrDefault(x => x.Name.LocalName == "Name")?.Value,
                    request.ControlName, StringComparison.OrdinalIgnoreCase));
            method = control?.Elements().FirstOrDefault(e => e.Name.LocalName == "Methods")
                ?.Elements().FirstOrDefault(e => e.Name.LocalName == "Method" &&
                    string.Equals(e.Elements().FirstOrDefault(x => x.Name.LocalName == "Name")?.Value,
                        request.MethodName, StringComparison.OrdinalIgnoreCase));
        }
        if (method is null)
            return ToolResult<object>.Fail("WRITE_VERIFY_FAILED", "Requested form method is absent on read-back.");

        var actualSource = method.Elements().FirstOrDefault(e => e.Name.LocalName == "Source")?.Value ?? string.Empty;
        if (!string.Equals(CanonicalSourceForComparison(actualSource), CanonicalSourceForComparison(request.Source), StringComparison.Ordinal))
            return ToolResult<object>.Fail("WRITE_VERIFY_FAILED",
                $"Persisted source for form method '{request.MethodName}' differs from the submitted canonical source.");

        return ToolResult<object>.Success(new
        {
            operation = request.Operation.ToString(),
            kind = "form",
            name = request.FormName,
            control = request.ControlName,
            method = request.MethodName,
            model,
            source = "bridge",
        });
    }
}

'@
$formMethodCommands = @'
using D365FO.Core;
using D365FO.Core.Bridge;
using D365FO.Core.Index;
using Spectre.Console.Cli;

namespace D365FO.Cli.Commands.Modify;

public sealed class ModifyAddFormMethodCommand : Command<ModifyAddFormMethodCommand.Settings>
{
    public sealed class Settings : D365OutputSettings
    {
        [CommandArgument(0, "<FORM>")] public string FormName { get; init; } = "";
        [CommandArgument(1, "<METHOD>")] public string MethodName { get; init; } = "";
        [CommandOption("--source <XPP>")] public string Source { get; init; } = "";
        [CommandOption("--model <MODEL>")] public string? Model { get; init; }
    }
    public override int Execute(CommandContext context, Settings settings)
    {
        MetadataRepository? repo = null; try { repo = RepoFactory.Create(); } catch { }
        return RenderHelpers.Render(OutputMode.Resolve(settings.Output),
            FormMethodModifyEngine.Modify(new FormMethodModifyEngine.ModifyRequest(
                FormMethodModifyEngine.Operation.AddFormMethod,
                settings.FormName, settings.MethodName, settings.Source, Model: settings.Model), repo));
    }
}

public sealed class ModifyAddControlMethodCommand : Command<ModifyAddControlMethodCommand.Settings>
{
    public sealed class Settings : D365OutputSettings
    {
        [CommandArgument(0, "<FORM>")] public string FormName { get; init; } = "";
        [CommandArgument(1, "<CONTROL>")] public string ControlName { get; init; } = "";
        [CommandArgument(2, "<METHOD>")] public string MethodName { get; init; } = "";
        [CommandOption("--source <XPP>")] public string Source { get; init; } = "";
        [CommandOption("--model <MODEL>")] public string? Model { get; init; }
    }
    public override int Execute(CommandContext context, Settings settings)
    {
        MetadataRepository? repo = null; try { repo = RepoFactory.Create(); } catch { }
        return RenderHelpers.Render(OutputMode.Resolve(settings.Output),
            FormMethodModifyEngine.Modify(new FormMethodModifyEngine.ModifyRequest(
                FormMethodModifyEngine.Operation.AddControlMethod,
                settings.FormName, settings.MethodName, settings.Source, settings.ControlName, settings.Model), repo));
    }
}

'@
$formMethodHandlers = @'
using D365FO.Core;
using D365FO.Core.Bridge;

namespace D365FO.Mcp;

public sealed partial class ToolHandlers
{
    public ToolResult<object> ModifyFormMethod(
        string action, string formName, string method, string source,
        string? control = null, string? model = null)
    {
        var operation = (action ?? string.Empty).Trim().ToLowerInvariant() switch
        {
            "add-form-method" => FormMethodModifyEngine.Operation.AddFormMethod,
            "add-control-method" => FormMethodModifyEngine.Operation.AddControlMethod,
            _ => (FormMethodModifyEngine.Operation?)null,
        };
        if (operation is null)
            return ToolResult<object>.Fail(D365FoErrorCodes.BadInput,
                $"Unknown form-method action '{action}'.");
        return FormMethodModifyEngine.Modify(new FormMethodModifyEngine.ModifyRequest(
            operation.Value, formName, method, source, control, model), _repo);
    }
}

'@
Add-OverlayFile 'src\D365FO.Core\Bridge\FormMethodModifyEngine.cs' $formMethodEngine
Add-OverlayFile 'src\D365FO.Cli\Commands\Modify\ModifyFormMethodCommands.cs' $formMethodCommands
Add-OverlayFile 'src\D365FO.Mcp\ToolHandlers.FormMethods.cs' $formMethodHandlers

$formMethodTests = @'
using System.Xml.Linq;
using D365FO.Core.Bridge;
using Xunit;

namespace D365FO.Core.Tests;

public sealed class FormMethodModifyEngineTests
{
    private const string FormXml =
        "<AxForm><Name>Fixture</Name><SourceCode>" +
        "<Methods><Method><Name>init</Name><Source><![CDATA[public void init()\n{\n}]]></Source></Method></Methods>" +
        "<DataSources /><DataControls><Control><Name>ValueControl</Name><Type>String</Type></Control></DataControls>" +
        "<Members /></SourceCode><DataSources /><Design /></AxForm>";

    [Fact]
    public void Adds_form_level_method()
    {
        var doc = XDocument.Parse(FormXml);
        var failure = FormMethodModifyEngine.ApplyToDocument(doc,
            new FormMethodModifyEngine.ModifyRequest(
                FormMethodModifyEngine.Operation.AddFormMethod,
                "Fixture", "helper",
                "    /// <summary>\n    /// Helper method.\n    /// </summary>\n    private void helper()\n    {\n    }",
                Model: "FixtureModel"));
        Assert.Null(failure);
        var source = doc.Root!.Element("SourceCode")!;
        Assert.Contains(source.Element("Methods")!.Elements("Method"),
            m => m.Element("Name")!.Value == "helper");
    }

    [Fact]
    public void Rejects_noncanonical_form_method_source_independent_of_neighbors()
    {
        var doc = XDocument.Parse(
            "<AxForm><Name>Fixture</Name><SourceCode><Methods />" +
            "<DataSources /><DataControls /><Members /></SourceCode><DataSources /><Design /></AxForm>");
        var failure = FormMethodModifyEngine.ApplyToDocument(doc,
            new FormMethodModifyEngine.ModifyRequest(
                FormMethodModifyEngine.Operation.AddFormMethod,
                "Fixture", "helper", "private void helper(){}", Model: "FixtureModel"));

        Assert.NotNull(failure);
        Assert.Equal("XPP_SOURCE_QUALITY_FAILED", failure!.Error!.Code);
    }

    [Fact]
    public void Adds_control_method_at_named_control_only()
    {
        var doc = XDocument.Parse(FormXml);
        var failure = FormMethodModifyEngine.ApplyToDocument(doc,
            new FormMethodModifyEngine.ModifyRequest(
                FormMethodModifyEngine.Operation.AddControlMethod,
                "Fixture", "modified",
                "    /// <summary>\n    /// Handles modified state.\n    /// </summary>\n    public boolean modified()\n    {\n        return true;\n    }",
                "ValueControl", "FixtureModel"));
        Assert.Null(failure);
        var source = doc.Root!.Element("SourceCode")!;
        var control = source.Element("DataControls")!.Elements("Control").Single();
        Assert.Contains(control.Element("Methods")!.Elements("Method"),
            m => m.Element("Name")!.Value == "modified");
        Assert.DoesNotContain(source.Element("Methods")!.Elements("Method"),
            m => m.Element("Name")!.Value == "modified");
    }
}

'@
Add-OverlayFile 'tests\D365FO.Core.Tests\FormMethodModifyEngineTests.cs' $formMethodTests

$formControlEngine = @'
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json.Nodes;
using System.Xml.Linq;
using D365FO.Core.Guardrails;
using D365FO.Core.Index;
using D365FO.Core.Scaffolding;

namespace D365FO.Core.Bridge;

public static class FormControlModifyEngine
{
    public enum Operation { SetProperty, PlaceBefore, PlaceAfter }

    private static readonly HashSet<string> AllowedProperties = new(StringComparer.OrdinalIgnoreCase)
    {
        "ExtendedDataType",
        "Label",
        "AutoDeclaration",
        "ReplaceOnLookup",
        "DataSource",
        "DataField",
        "DataMethod",
        "Caption",
        "Text",
        "CountryRegionCodes",
        "AllowEdit",
        "Enabled",
        "Visible",
    };

    public sealed record ModifyRequest(
        Operation Operation,
        string Kind,
        string ObjectName,
        string ControlName,
        string? Property = null,
        string? Value = null,
        string? Sibling = null,
        string? Model = null);

    private sealed record LocatedControl(XElement PropertyNode, XElement PlacementNode, bool ExtensionWrapper);

    public static ToolResult<object> Modify(
        ModifyRequest request, MetadataRepository? repo, BridgeOptions? bridgeOptions = null)
    {
        var options = bridgeOptions ?? MethodModifyEngine.DefaultBridgeOptions();
        if (!BridgeClient.IsAvailable(options))
            return ToolResult<object>.Fail(D365FoErrorCodes.BridgeRequired,
                "Form control mutation requires D365FO.Bridge.");

        using var client = new BridgeClient(options);
        return ModifyCore(request, repo, client);
    }

    private static string NormalizeKind(string kind) =>
        (kind ?? string.Empty).Trim().ToLowerInvariant() switch
        {
            "form" => "form",
            "formextension" or "form-extension" => "formextension",
            _ => string.Empty,
        };

    private static XElement? DirectChild(XElement parent, string localName) =>
        parent.Elements().FirstOrDefault(e => e.Name.LocalName == localName);

    private static bool Named(XElement node, string name) =>
        string.Equals(DirectChild(node, "Name")?.Value, name, StringComparison.OrdinalIgnoreCase);

    private static ToolResult<object>? Locate(
        XDocument doc, string kind, string controlName, out LocatedControl? located)
    {
        located = null;
        var candidates = new List<LocatedControl>();

        if (kind == "formextension")
        {
            foreach (var wrapper in doc.Descendants().Where(e => e.Name.LocalName == "AxFormExtensionControl"))
            {
                var formControl = DirectChild(wrapper, "FormControl");
                if (formControl is not null && Named(formControl, controlName))
                    candidates.Add(new LocatedControl(formControl, wrapper, true));
            }
        }

        foreach (var control in doc.Descendants().Where(e => e.Name.LocalName == "AxFormControl"))
        {
            if (Named(control, controlName))
                candidates.Add(new LocatedControl(control, control, false));
        }

        if (candidates.Count == 0)
            return ToolResult<object>.Fail("FORM_CONTROL_NOT_FOUND",
                $"Control '{controlName}' was not found.");
        if (candidates.Count != 1)
            return ToolResult<object>.Fail("FORM_CONTROL_AMBIGUOUS",
                $"Control '{controlName}' matched {candidates.Count} metadata nodes.");

        located = candidates[0];
        return null;
    }

    internal static ToolResult<object>? ApplyToDocument(XDocument doc, ModifyRequest request)
    {
        var operation = request.Operation switch
        {
            Operation.SetProperty => ObjectModifyEngine.Operation.SetControlProperty,
            Operation.PlaceBefore => ObjectModifyEngine.Operation.PlaceControlBefore,
            Operation.PlaceAfter => ObjectModifyEngine.Operation.PlaceControlAfter,
            _ => throw new InvalidOperationException("Unsupported form-control operation."),
        };
        var (_applied, failure) = ObjectModifyEngine.ApplyFormControlOperationForTests(doc,
            new ObjectModifyEngine.ModifyRequest
            {
                Operation = operation,
                Kind = request.Kind,
                ObjectName = request.ObjectName,
                Member = request.ControlName,
                ControlProperty = request.Property,
                Value = request.Value,
                Sibling = request.Sibling,
                Model = request.Model,
            });
        return failure;
    }

    internal static ToolResult<object> ModifyCore(
        ModifyRequest request, MetadataRepository? repo, BridgeClient client, string? journalDbOverride = null)
    {
        var kind = NormalizeKind(request.Kind);
        if (kind.Length == 0 || string.IsNullOrWhiteSpace(request.ObjectName) ||
            string.IsNullOrWhiteSpace(request.ControlName) || string.IsNullOrWhiteSpace(request.Model))
            return ToolResult<object>.Fail(D365FoErrorCodes.BadInput,
                "Kind, object, control and --model are required for form-control mutation.");

        JsonObject? read = client.SendAsync("readObjectXml",
            new JsonObject { ["kind"] = kind, ["name"] = request.ObjectName }).GetAwaiter().GetResult();
        if ((bool?)read?["ok"] != true || string.IsNullOrWhiteSpace((string?)read?["xml"]))
            return ToolResult<object>.Fail("READ_FAILED",
                $"Bridge could not read {kind} '{request.ObjectName}'.");

        var before = (string)read!["xml"]!;
        XDocument doc;
        try { doc = XDocument.Parse(before); }
        catch (Exception ex) { return ToolResult<object>.Fail("READ_FAILED", ex.Message); }

        var failure = ApplyToDocument(doc, request);
        if (failure is not null) return failure;

        ContractOrderCanonicalizer.Apply(doc);
        var after = doc.ToString(SaveOptions.DisableFormatting);
        var description = request.Operation switch
        {
            Operation.SetProperty =>
                $"modify control-property {kind} {request.ObjectName} {request.ControlName} {request.Property}",
            Operation.PlaceBefore =>
                $"modify control-position {kind} {request.ObjectName} {request.ControlName} before {request.Sibling}",
            _ =>
                $"modify control-position {kind} {request.ObjectName} {request.ControlName} after {request.Sibling}",
        };
        ObjectModifyEngine.RecordJournalEntry(
            new ObjectModifyEngine.WriteTarget(kind, request.ObjectName, request.Model!, IsExtension: kind == "formextension", Exists: true),
            before, description, journalDbOverride);

        JsonObject? write = client.SendAsync("updateObject", new JsonObject
        {
            ["kind"] = kind, ["name"] = request.ObjectName, ["model"] = request.Model, ["xml"] = after,
        }).GetAwaiter().GetResult();
        if ((bool?)write?["ok"] != true)
            return ToolResult<object>.Fail(D365FoErrorCodes.WriteFailed,
                (string?)write?["message"] ?? "Bridge form-control update failed.");

        JsonObject? verify = client.SendAsync("readObjectXml",
            new JsonObject { ["kind"] = kind, ["name"] = request.ObjectName }).GetAwaiter().GetResult();
        var verifyXml = (string?)verify?["xml"];
        if ((bool?)verify?["ok"] != true || string.IsNullOrWhiteSpace(verifyXml))
            return ToolResult<object>.Fail("WRITE_VERIFY_FAILED",
                "Form-control write completed but read-back failed.");

        XDocument verifyDoc;
        try { verifyDoc = XDocument.Parse(verifyXml); }
        catch (Exception ex) { return ToolResult<object>.Fail("WRITE_VERIFY_FAILED", ex.Message); }

        var locateVerify = Locate(verifyDoc, kind, request.ControlName, out var verifyTarget);
        if (locateVerify is not null || verifyTarget is null)
            return ToolResult<object>.Fail("WRITE_VERIFY_FAILED",
                "Requested form control is absent on read-back.");

        if (request.Operation == Operation.SetProperty)
        {
            var actual = DirectChild(verifyTarget.PropertyNode, request.Property!)?.Value;
            if (!string.Equals(actual, request.Value, StringComparison.Ordinal))
                return ToolResult<object>.Fail("WRITE_VERIFY_FAILED",
                    $"Property '{request.Property}' did not persist on control '{request.ControlName}'.");
        }
        else if (verifyTarget.ExtensionWrapper)
        {
            var actualPosition = DirectChild(verifyTarget.PlacementNode, "PositionType")?.Value;
            var actualSibling = DirectChild(verifyTarget.PlacementNode, "PreviousSibling")?.Value;
            if (request.Operation != Operation.PlaceAfter ||
                !string.Equals(actualPosition, "AfterItem", StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(actualSibling, request.Sibling, StringComparison.OrdinalIgnoreCase))
                return ToolResult<object>.Fail("WRITE_VERIFY_FAILED",
                    "Form-extension control placement did not persist.");
        }
        else
        {
            var locateSibling = Locate(verifyDoc, kind, request.Sibling!, out var verifySibling);
            if (locateSibling is not null || verifySibling is null ||
                !ReferenceEquals(verifyTarget.PlacementNode.Parent, verifySibling.PlacementNode.Parent))
                return ToolResult<object>.Fail("WRITE_VERIFY_FAILED",
                    "Placement sibling could not be verified.");

            var siblings = verifyTarget.PlacementNode.Parent!.Elements()
                .Where(e => e.Name.LocalName == "AxFormControl").ToList();
            var targetIndex = siblings.IndexOf(verifyTarget.PlacementNode);
            var siblingIndex = siblings.IndexOf(verifySibling.PlacementNode);
            var ok = request.Operation == Operation.PlaceBefore
                ? targetIndex + 1 == siblingIndex
                : siblingIndex + 1 == targetIndex;
            if (!ok)
                return ToolResult<object>.Fail("WRITE_VERIFY_FAILED",
                    "Inline form-control placement did not persist.");
        }

        return ToolResult<object>.Success(new
        {
            operation = request.Operation.ToString(),
            kind,
            name = request.ObjectName,
            control = request.ControlName,
            property = request.Property,
            value = request.Value,
            sibling = request.Sibling,
            model = request.Model,
            source = "bridge",
        });
    }
}

'@

$formControlCommands = @'
using D365FO.Core;
using D365FO.Core.Bridge;
using D365FO.Core.Index;
using Spectre.Console.Cli;

namespace D365FO.Cli.Commands.Modify;

public sealed class ModifyControlPropertyCommand : Command<ModifyControlPropertyCommand.Settings>
{
    public sealed class Settings : D365OutputSettings
    {
        [CommandArgument(0, "<KIND>")] public string Kind { get; init; } = "";
        [CommandArgument(1, "<OBJECT>")] public string ObjectName { get; init; } = "";
        [CommandArgument(2, "<CONTROL>")] public string ControlName { get; init; } = "";
        [CommandArgument(3, "<PROPERTY>")] public string Property { get; init; } = "";
        [CommandArgument(4, "<VALUE>")] public string Value { get; init; } = "";
        [CommandOption("--model <MODEL>")] public string? Model { get; init; }
    }

    public override int Execute(CommandContext context, Settings settings)
    {
        MetadataRepository? repo = null; try { repo = RepoFactory.Create(); } catch { }
        return RenderHelpers.Render(OutputMode.Resolve(settings.Output),
            FormControlModifyEngine.Modify(new FormControlModifyEngine.ModifyRequest(
                FormControlModifyEngine.Operation.SetProperty,
                settings.Kind, settings.ObjectName, settings.ControlName,
                settings.Property, settings.Value, Model: settings.Model), repo));
    }
}

public sealed class ModifyControlPositionCommand : Command<ModifyControlPositionCommand.Settings>
{
    public sealed class Settings : D365OutputSettings
    {
        [CommandArgument(0, "<KIND>")] public string Kind { get; init; } = "";
        [CommandArgument(1, "<OBJECT>")] public string ObjectName { get; init; } = "";
        [CommandArgument(2, "<CONTROL>")] public string ControlName { get; init; } = "";
        [CommandArgument(3, "<RELATION>")] public string Relation { get; init; } = "";
        [CommandArgument(4, "<SIBLING>")] public string Sibling { get; init; } = "";
        [CommandOption("--model <MODEL>")] public string? Model { get; init; }
    }

    public override int Execute(CommandContext context, Settings settings)
    {
        var operation = (settings.Relation ?? string.Empty).Trim().ToLowerInvariant() switch
        {
            "before" => FormControlModifyEngine.Operation.PlaceBefore,
            "after" => FormControlModifyEngine.Operation.PlaceAfter,
            _ => (FormControlModifyEngine.Operation?)null,
        };
        if (operation is null)
            return RenderHelpers.Render(OutputMode.Resolve(settings.Output),
                ToolResult<object>.Fail(D365FoErrorCodes.BadInput, "<RELATION> must be before or after."));

        MetadataRepository? repo = null; try { repo = RepoFactory.Create(); } catch { }
        return RenderHelpers.Render(OutputMode.Resolve(settings.Output),
            FormControlModifyEngine.Modify(new FormControlModifyEngine.ModifyRequest(
                operation.Value, settings.Kind, settings.ObjectName, settings.ControlName,
                Sibling: settings.Sibling, Model: settings.Model), repo));
    }
}

'@

$formControlHandlers = @'
using D365FO.Core;
using D365FO.Core.Bridge;

namespace D365FO.Mcp;

public sealed partial class ToolHandlers
{
    public ToolResult<object> ModifyFormControl(
        string action, string kind, string objectName, string control,
        string? property = null, string? value = null, string? sibling = null, string? model = null)
    {
        var operation = (action ?? string.Empty).Trim().ToLowerInvariant() switch
        {
            "set-property" => FormControlModifyEngine.Operation.SetProperty,
            "place-before" => FormControlModifyEngine.Operation.PlaceBefore,
            "place-after" => FormControlModifyEngine.Operation.PlaceAfter,
            _ => (FormControlModifyEngine.Operation?)null,
        };
        if (operation is null)
            return ToolResult<object>.Fail(D365FoErrorCodes.BadInput,
                $"Unknown form-control action '{action}'.");

        return FormControlModifyEngine.Modify(new FormControlModifyEngine.ModifyRequest(
            operation.Value, kind, objectName, control, property, value, sibling, model), _repo);
    }
}

'@

$formControlTests = @'
using System.Linq;
using System.Xml.Linq;
using D365FO.Core.Bridge;
using Xunit;

namespace D365FO.Core.Tests;

public sealed class FormControlModifyEngineTests
{
    private const string FormXml =
        "<AxForm><Name>Fixture</Name><SourceCode><Methods/><DataSources/><DataControls/><Members/></SourceCode>" +
        "<DataSources/><Design><Controls>" +
        "<AxFormControl><Name>GlobalGroup</Name><Type>Group</Type><FormControlExtension/></AxFormControl>" +
        "<AxFormControl><Name>ItalianGroup</Name><Type>Group</Type><FormControlExtension/></AxFormControl>" +
        "</Controls></Design></AxForm>";

    private const string FormExtensionXml =
        "<AxFormExtension><Name>Base.Extension</Name><ControlModifications/><Controls>" +
        "<AxFormExtensionControl><Name>WrapperA</Name><FormControl><Name>GridA</Name><Type>String</Type><FormControlExtension/></FormControl><Parent>Grid</Parent></AxFormExtensionControl>" +
        "<AxFormExtensionControl><Name>WrapperB</Name><FormControl><Name>GridB</Name><Type>String</Type><FormControlExtension/></FormControl><Parent>Grid</Parent></AxFormExtensionControl>" +
        "</Controls></AxFormExtension>";

    [Fact]
    public void Sets_whitelisted_control_property()
    {
        var doc = XDocument.Parse(FormXml);
        var failure = FormControlModifyEngine.ApplyToDocument(doc,
            new FormControlModifyEngine.ModifyRequest(
                FormControlModifyEngine.Operation.SetProperty,
                "form", "Fixture", "GlobalGroup",
                "AutoDeclaration", "Yes", Model: "FixtureModel"));
        Assert.Null(failure);
        var control = doc.Descendants().Single(e =>
            e.Name.LocalName == "AxFormControl" && e.Element("Name")?.Value == "GlobalGroup");
        Assert.Equal("Yes", control.Element("AutoDeclaration")?.Value);
    }

    [Fact]
    public void Rejects_unapproved_control_property()
    {
        var doc = XDocument.Parse(FormXml);
        var failure = FormControlModifyEngine.ApplyToDocument(doc,
            new FormControlModifyEngine.ModifyRequest(
                FormControlModifyEngine.Operation.SetProperty,
                "form", "Fixture", "GlobalGroup",
                "ArbitraryMetadata", "x", Model: "FixtureModel"));
        Assert.NotNull(failure);
        Assert.False(failure!.Ok);
    }

    [Fact]
    public void Reorders_inline_form_controls()
    {
        var doc = XDocument.Parse(FormXml);
        var failure = FormControlModifyEngine.ApplyToDocument(doc,
            new FormControlModifyEngine.ModifyRequest(
                FormControlModifyEngine.Operation.PlaceBefore,
                "form", "Fixture", "ItalianGroup",
                Sibling: "GlobalGroup", Model: "FixtureModel"));
        Assert.Null(failure);
        var controls = doc.Descendants().First(e => e.Name.LocalName == "Controls")
            .Elements().Where(e => e.Name.LocalName == "AxFormControl")
            .Select(e => e.Element("Name")?.Value).ToArray();
        Assert.Equal(new[] { "ItalianGroup", "GlobalGroup" }, controls);
    }

    [Fact]
    public void Batch_parser_exposes_form_control_steps_for_one_object()
    {
        var steps = BatchStepParser.Parse(
            "[{\"operation\":\"control-property\",\"member\":\"GlobalGroup\",\"property\":\"AutoDeclaration\",\"value\":\"Yes\"}," +
            "{\"operation\":\"control-before\",\"member\":\"ItalianGroup\",\"sibling\":\"GlobalGroup\"}]",
            "form", "Fixture", "FixtureModel");

        Assert.Equal(2, steps.Count);
        Assert.Equal(ObjectModifyEngine.Operation.SetControlProperty, steps[0].Operation);
        Assert.Equal("AutoDeclaration", steps[0].ControlProperty);
        Assert.Equal("Yes", steps[0].Value);
        Assert.Equal(ObjectModifyEngine.Operation.PlaceControlBefore, steps[1].Operation);
        Assert.Equal("GlobalGroup", steps[1].Sibling);

        var doc = XDocument.Parse(FormXml);
        foreach (var step in steps)
        {
            var (_applied, failure) = ObjectModifyEngine.ApplyFormControlOperationForTests(doc, step);
            Assert.Null(failure);
        }

        var group = doc.Descendants().Single(e =>
            e.Name.LocalName == "AxFormControl" && e.Element("Name")?.Value == "GlobalGroup");
        Assert.Equal("Yes", group.Element("AutoDeclaration")?.Value);
        var controls = doc.Descendants().First(e => e.Name.LocalName == "Controls")
            .Elements().Where(e => e.Name.LocalName == "AxFormControl")
            .Select(e => e.Element("Name")?.Value).ToArray();
        Assert.Equal(new[] { "ItalianGroup", "GlobalGroup" }, controls);
    }

    [Fact]
    public void Sets_extension_after_item_placement_on_wrapper()
    {
        var doc = XDocument.Parse(FormExtensionXml);
        var failure = FormControlModifyEngine.ApplyToDocument(doc,
            new FormControlModifyEngine.ModifyRequest(
                FormControlModifyEngine.Operation.PlaceAfter,
                "formextension", "Base.Extension", "GridB",
                Sibling: "GridA", Model: "FixtureModel"));
        Assert.Null(failure);
        var wrapper = doc.Descendants().Single(e =>
            e.Name.LocalName == "AxFormExtensionControl" &&
            e.Elements().FirstOrDefault(x => x.Name.LocalName == "FormControl")
                ?.Elements().FirstOrDefault(x => x.Name.LocalName == "Name")?.Value == "GridB");
        Assert.Equal("AfterItem", wrapper.Elements().First(e => e.Name.LocalName == "PositionType").Value);
        Assert.Equal("GridA", wrapper.Elements().First(e => e.Name.LocalName == "PreviousSibling").Value);
    }
}

'@
Add-OverlayFile 'src\D365FO.Core\Bridge\FormControlModifyEngine.cs' $formControlEngine
Add-OverlayFile 'src\D365FO.Cli\Commands\Modify\ModifyFormControlCommands.cs' $formControlCommands
Add-OverlayFile 'src\D365FO.Mcp\ToolHandlers.FormControls.cs' $formControlHandlers
Add-OverlayFile 'tests\D365FO.Core.Tests\FormControlModifyEngineTests.cs' $formControlTests

$labelEntryEngine = @'
using System.Text;
using D365FO.Core;

namespace D365FO.Core.Bridge;

public static class LabelEntryModifyEngine
{
    public sealed record ModifyRequest(
        string LabelFile,
        string LabelId,
        string Language,
        string Value,
        string Comment,
        string Model);

    public static (string Text, bool Changed, string? Error) ApplyToText(
        string existing, string labelId, string value, string comment)
    {
        if (string.IsNullOrWhiteSpace(labelId) || labelId.Any(ch => !(char.IsLetterOrDigit(ch) || ch == '_')))
            return (existing, false, "Label id must contain only letters, digits or underscore.");
        var newline = existing.Contains("\r\n", StringComparison.Ordinal) ? "\r\n" : "\n";
        var lines = existing.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n').ToList();
        for (var i = 0; i < lines.Count; i++)
        {
            if (!lines[i].StartsWith(labelId + "=", StringComparison.Ordinal)) continue;
            var existingValue = lines[i][(labelId.Length + 1)..];
            var existingComment = i + 1 < lines.Count && lines[i + 1].StartsWith(" ;", StringComparison.Ordinal)
                ? lines[i + 1][2..]
                : string.Empty;
            if (existingValue == value && existingComment == comment)
                return (existing, false, null);
            return (existing, false, $"LABEL_CONFLICT: '{labelId}' already exists with different value/comment.");
        }

        var suffix = existing.Length == 0 || existing.EndsWith("\n", StringComparison.Ordinal) || existing.EndsWith("\r", StringComparison.Ordinal)
            ? string.Empty : newline;
        var updated = existing + suffix + labelId + "=" + value + newline + " ;" + comment + newline;
        return (updated, true, null);
    }

    private static bool IsSafePathSegment(string value) =>
        !string.IsNullOrWhiteSpace(value) &&
        value != "." &&
        value != ".." &&
        string.Equals(value, Path.GetFileName(value), StringComparison.Ordinal) &&
        !value.Contains(Path.DirectorySeparatorChar) &&
        !value.Contains(Path.AltDirectorySeparatorChar);

    public static ToolResult<object> Modify(ModifyRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.LabelFile) ||
            string.IsNullOrWhiteSpace(request.Language) ||
            string.IsNullOrWhiteSpace(request.Model) ||
            string.IsNullOrWhiteSpace(request.Value))
            return ToolResult<object>.Fail(D365FoErrorCodes.BadInput,
                "Label file, id, language, value and model are required.");
        if (!IsSafePathSegment(request.LabelFile) || !IsSafePathSegment(request.Language))
            return ToolResult<object>.Fail(D365FoErrorCodes.BadInput,
                "Label file and language must be single safe path segments.");
        if (request.Value.Contains('\r') || request.Value.Contains('\n') ||
            request.Comment.Contains('\r') || request.Comment.Contains('\n'))
            return ToolResult<object>.Fail(D365FoErrorCodes.BadInput,
                "Label value/comment must not contain line breaks.");

        var root = Environment.GetEnvironmentVariable("D365FO_CUSTOM_PACKAGES_PATH");
        if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root))
            return ToolResult<object>.Fail(D365FoErrorCodes.WriteFailed,
                "D365FO_CUSTOM_PACKAGES_PATH is unavailable.");

        static string Key(string value) =>
            new(value.Where(char.IsLetterOrDigit).Select(char.ToLowerInvariant).ToArray());

        var modelDir = Directory.GetDirectories(root, "*", SearchOption.TopDirectoryOnly)
            .FirstOrDefault(path => Key(Path.GetFileName(path)) == Key(request.Model));
        if (modelDir is null)
            return ToolResult<object>.Fail(D365FoErrorCodes.WriteFailed,
                $"Writable model directory '{request.Model}' was not found under the custom packages root.");

        var relative = Path.Combine("AxLabelFile", "LabelResources", request.Language,
            $"{request.LabelFile}.{request.Language}.label.txt");
        var path = Path.Combine(modelDir, relative);
        if (!File.Exists(path))
            return ToolResult<object>.Fail(D365FoErrorCodes.WriteFailed,
                $"Label resource does not exist: {relative}");

        var bytes = File.ReadAllBytes(path);
        var hadBom = bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF;
        var existing = Encoding.UTF8.GetString(bytes, hadBom ? 3 : 0, bytes.Length - (hadBom ? 3 : 0));
        var applied = ApplyToText(existing, request.LabelId, request.Value, request.Comment);
        if (applied.Error is not null)
            return ToolResult<object>.Fail(D365FoErrorCodes.AlreadyExists, applied.Error);
        if (!applied.Changed)
            return ToolResult<object>.Success(new
            {
                operation = "AddLabelEntry",
                labelFile = request.LabelFile,
                labelId = request.LabelId,
                language = request.Language,
                model = request.Model,
                source = "filesystem",
                changed = false,
            });

        ObjectModifyEngine.RecordJournalEntry(
            new ObjectModifyEngine.WriteTarget("label", request.LabelFile, request.Model, IsExtension: false, Exists: true),
            existing,
            $"modify label-entry {request.LabelFile} {request.LabelId} --language {request.Language}",
            null);

        var temp = path + "." + Environment.ProcessId + ".tmp";
        try
        {
            using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                if (hadBom) stream.Write(new byte[] { 0xEF, 0xBB, 0xBF });
                var payload = Encoding.UTF8.GetBytes(applied.Text);
                stream.Write(payload, 0, payload.Length);
                stream.Flush(true);
            }
            File.Move(temp, path, true);
        }
        finally
        {
            if (File.Exists(temp)) File.Delete(temp);
        }

        var verifyBytes = File.ReadAllBytes(path);
        var verifyBom = verifyBytes.Length >= 3 && verifyBytes[0] == 0xEF && verifyBytes[1] == 0xBB && verifyBytes[2] == 0xBF;
        var verify = Encoding.UTF8.GetString(verifyBytes, verifyBom ? 3 : 0, verifyBytes.Length - (verifyBom ? 3 : 0));
        var verification = ApplyToText(verify, request.LabelId, request.Value, request.Comment);
        if (verification.Error is not null || verification.Changed)
            return ToolResult<object>.Fail("WRITE_VERIFY_FAILED",
                $"Label entry '{request.LabelId}' is absent or different on read-back.");

        return ToolResult<object>.Success(new
        {
            operation = "AddLabelEntry",
            labelFile = request.LabelFile,
            labelId = request.LabelId,
            language = request.Language,
            model = request.Model,
            source = "filesystem",
            changed = true,
        });
    }
}

'@
$labelEntryCommand = @'
using D365FO.Core;
using D365FO.Core.Bridge;
using Spectre.Console.Cli;

namespace D365FO.Cli.Commands.Modify;

public sealed class ModifyLabelEntryCommand : Command<ModifyLabelEntryCommand.Settings>
{
    public sealed class Settings : D365OutputSettings
    {
        [CommandArgument(0, "<LABELFILE>")] public string LabelFile { get; init; } = "";
        [CommandArgument(1, "<ID>")] public string LabelId { get; init; } = "";
        [CommandOption("--language <LANGUAGE>")] public string Language { get; init; } = "";
        [CommandOption("--value <VALUE>")] public string Value { get; init; } = "";
        [CommandOption("--comment <COMMENT>")] public string Comment { get; init; } = "";
        [CommandOption("--model <MODEL>")] public string Model { get; init; } = "";
    }

    public override int Execute(CommandContext context, Settings settings) =>
        RenderHelpers.Render(OutputMode.Resolve(settings.Output),
            LabelEntryModifyEngine.Modify(new LabelEntryModifyEngine.ModifyRequest(
                settings.LabelFile, settings.LabelId, settings.Language,
                settings.Value, settings.Comment, settings.Model)));
}

'@
$labelEntryTests = @'
using D365FO.Core.Bridge;
using Xunit;

namespace D365FO.Core.Tests;

public sealed class LabelEntryModifyEngineTests
{
    [Fact]
    public void Adds_entry_and_is_idempotent()
    {
        var first = LabelEntryModifyEngine.ApplyToText(
            "Existing=Value\n ;Comment\n", "NewLabel", "New value", "Ticket");
        Assert.True(first.Changed);
        Assert.Null(first.Error);
        Assert.Contains("NewLabel=New value\n ;Ticket\n", first.Text);

        var second = LabelEntryModifyEngine.ApplyToText(
            first.Text, "NewLabel", "New value", "Ticket");
        Assert.False(second.Changed);
        Assert.Null(second.Error);
    }

    [Fact]
    public void Rejects_conflicting_existing_entry()
    {
        var result = LabelEntryModifyEngine.ApplyToText(
            "NewLabel=Other\n ;Ticket\n", "NewLabel", "New value", "Ticket");
        Assert.False(result.Changed);
        Assert.Contains("LABEL_CONFLICT", result.Error);
    }

    [Fact]
    public void Rejects_path_traversal_before_filesystem_access()
    {
        var result = LabelEntryModifyEngine.Modify(
            new LabelEntryModifyEngine.ModifyRequest(
                "..\\OtherModule", "NewLabel", "en-US", "New value", "Ticket", "FixtureModel"));
        Assert.False(result.Ok);
        Assert.Equal(D365FoErrorCodes.BadInput, result.Error!.Code);
    }

    [Fact]
    public void Rejects_line_break_injection_before_filesystem_access()
    {
        var result = LabelEntryModifyEngine.Modify(
            new LabelEntryModifyEngine.ModifyRequest(
                "DEDCoreModule", "NewLabel", "en-US", "New value\nInjected=Bad", "Ticket", "FixtureModel"));
        Assert.False(result.Ok);
        Assert.Equal(D365FoErrorCodes.BadInput, result.Error!.Code);
    }
}

'@
Add-OverlayFile 'src\D365FO.Core\Bridge\LabelEntryModifyEngine.cs' $labelEntryEngine
Add-OverlayFile 'src\D365FO.Cli\Commands\Modify\ModifyLabelEntryCommand.cs' $labelEntryCommand
Add-OverlayFile 'tests\D365FO.Core.Tests\LabelEntryModifyEngineTests.cs' $labelEntryTests

Replace-Exact 'src\D365FO.Cli\CliApp.cs' @'
                b.AddCommand<ModifyMethodCommand>("method").WithDescription("Replace the body of an existing method on a class/table/edt/form.");
                b.AddCommand<ModifyPropertyCommand>("property").WithDescription("Set a property (Label, ConfigurationKey, TableGroup, …) on a live object.");
'@ @'
                b.AddCommand<ModifyMethodCommand>("method").WithDescription("Replace the body of an existing method on a class/table/edt/form.");
                b.AddCommand<ModifyAddClassFieldCommand>("add-class-field").WithDescription("Add a private/protected member variable to an existing class through D365FO.Bridge.");
                b.AddCommand<ModifyAddClassConstantCommand>("add-class-constant").WithDescription("Add an initialized private/protected constant to an existing class through D365FO.Bridge.");
                b.AddCommand<ModifyAddClassMethodCommand>("add-class-method").WithDescription("Add a new method to an existing class through D365FO.Bridge.");
                b.AddCommand<ModifyAddFormMethodCommand>("add-form-method").WithDescription("Add a new form-level method to an existing form through D365FO.Bridge.");
                b.AddCommand<ModifyAddControlMethodCommand>("add-control-method").WithDescription("Add a new method override to an existing form control through D365FO.Bridge.");
                b.AddCommand<ModifyControlPropertyCommand>("control-property").WithDescription("Set one approved property on an existing form or form-extension control through D365FO.Bridge.");
                b.AddCommand<ModifyControlPositionCommand>("control-position").WithDescription("Place an existing form or form-extension control relative to a sibling through D365FO.Bridge.");
                b.AddCommand<ModifyLabelEntryCommand>("label-entry").WithDescription("Add one exact label entry to an existing model label resource.");
                b.AddCommand<ModifyPropertyCommand>("property").WithDescription("Set a property (Label, ConfigurationKey, TableGroup, …) on a live object.");
'@

Replace-Exact 'src\D365FO.Mcp\ToolCatalog.cs' @'
        "generate_object", "labels", "modify_method", "modify_object", "undo_last_modification",
'@ @'
        "generate_object", "labels", "modify_method", "modify_object", "modify_class_member", "modify_form_method", "modify_form_control", "undo_last_modification",
'@

Replace-Exact 'src\D365FO.Mcp\ToolCatalog.cs' @'
        new Descriptor("modify_object",
'@ @'
        new Descriptor("modify_class_member",
            "Typed additions to an EXISTING AxClass through D365FO.Bridge. action=add-field adds a private/protected " +
            "member variable to SourceCode/Declaration (type required, access optional and defaults protected). " +
            "action=add-method adds a new structured Method node (source is the full X++ method declaration). " +
            "All paths journal the exact pre-image and verify the member by bridge read-back. No on-disk fallback.",
            Schema(("action", "string", true), ("className", "string", true), ("member", "string", true),
                   ("type", "string", false), ("access", "string", false), ("source", "string", false),
                   ("model", "string", false), ("initializer", "string", false)),
            (h, p) => h.ModifyClassMember(Str(p, "action"), Str(p, "className"), Str(p, "member"),
                StrOrNull(p, "type"), StrOrNull(p, "access"), StrOrNull(p, "source"), StrOrNull(p, "model"),
                StrOrNull(p, "initializer"))),

        new Descriptor("modify_form_method",
            "Typed insertion of a new form-level or control-level method into an existing AxForm through D365FO.Bridge.",
            Schema(("action", "string", true), ("formName", "string", true), ("method", "string", true),
                   ("source", "string", true), ("control", "string", false), ("model", "string", false)),
            (h, p) => h.ModifyFormMethod(Str(p, "action"), Str(p, "formName"), Str(p, "method"),
                Str(p, "source"), StrOrNull(p, "control"), StrOrNull(p, "model"))),

        new Descriptor("modify_form_control",
            "Typed property and placement mutation for an EXISTING AxForm/AxFormExtension control through D365FO.Bridge. " +
            "action=set-property accepts only the overlay whitelist; place-before/place-after preserve form metadata structure and verify by bridge read-back.",
            Schema(("action", "string", true), ("kind", "string", true), ("objectName", "string", true),
                   ("control", "string", true), ("property", "string", false), ("value", "string", false),
                   ("sibling", "string", false), ("model", "string", false)),
            (h, p) => h.ModifyFormControl(Str(p, "action"), Str(p, "kind"), Str(p, "objectName"),
                Str(p, "control"), StrOrNull(p, "property"), StrOrNull(p, "value"),
                StrOrNull(p, "sibling"), StrOrNull(p, "model"))),

        new Descriptor("modify_object",
'@

Replace-Exact 'src\D365FO.Cli\Commands\Agent\SchemaCommand.cs' @'
        C("modify add-control", "Add a control to a live form's design, optionally bound to a datasource field.", ["<FORM>", "<CONTROL>"], ["--type", "--parent", "--datasource", "--datafield", "--model", "--extension", "--extension-model", "--require-extension", "--output"], ["modify_object (action=add-control)"]),
'@ @'
        C("modify add-class-field", "Add a private/protected member variable to an existing AxClass.", ["<CLASS>", "<FIELD>"], ["--type", "--access", "--model", "--output"], ["modify_class_member (action=add-field)"]),
        C("modify add-class-constant", "Add an initialized private/protected constant to an existing AxClass.", ["<CLASS>", "<CONSTANT>"], ["--type", "--initializer", "--access", "--model", "--output"], ["modify_class_member (action=add-constant)"]),
        C("modify add-class-method", "Add a new structured method to an existing AxClass.", ["<CLASS>", "<METHOD>"], ["--source", "--model", "--output"], ["modify_class_member (action=add-method)"]),
        C("modify add-form-method", "Add a new form-level method to an existing AxForm.", ["<FORM>", "<METHOD>"], ["--source", "--model", "--output"], ["modify_form_method (action=add-form-method)"]),
        C("modify add-control-method", "Add a new method override to an existing AxForm control.", ["<FORM>", "<CONTROL>", "<METHOD>"], ["--source", "--model", "--output"], ["modify_form_method (action=add-control-method)"]),
        C("modify control-property", "Set one approved property on an existing form or form-extension control.", ["<KIND>", "<OBJECT>", "<CONTROL>", "<PROPERTY>", "<VALUE>"], ["--model", "--output"], ["modify_form_control (action=set-property)"]),
        C("modify control-position", "Place an existing form or form-extension control before/after a sibling.", ["<KIND>", "<OBJECT>", "<CONTROL>", "<RELATION>", "<SIBLING>"], ["--model", "--output"], ["modify_form_control (action=place-before/place-after)"]),
        C("modify label-entry", "Add one exact label entry to an existing label resource.", ["<LABELFILE>", "<ID>"], ["--language", "--value", "--comment", "--model", "--output"], []),
        C("modify add-control", "Add a control to a live form's design, optionally bound to a datasource field.", ["<FORM>", "<CONTROL>"], ["--type", "--parent", "--datasource", "--datafield", "--model", "--extension", "--extension-model", "--require-extension", "--output"], ["modify_object (action=add-control)"]),
'@

$phase6Script = Join-Path $PSScriptRoot 'ApplyPhase6.py'
if (-not (Test-Path -LiteralPath $phase6Script -PathType Leaf)) { throw "PHASE6_OVERLAY_MISSING: $phase6Script" }
& python $phase6Script $CandidateSourceRoot
if ($LASTEXITCODE -ne 0) { throw "PHASE6_OVERLAY_FAILED: exit code $LASTEXITCODE" }

Write-Host 'Ninja class-member + Phase 6 source overlay applied.'
