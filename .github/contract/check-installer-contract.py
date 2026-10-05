#!/usr/bin/env python3
import argparse
import json
import re
import sys
from pathlib import Path

STAGE_START = "# Stage definitions -- the single source of truth."
STAGE_END = "# Stage workers"

NETWORK_PATTERNS = {
    "Invoke-WebRequest": r"\bInvoke-WebRequest\b",
    "Invoke-RestMethod": r"\bInvoke-RestMethod\b",
    "irm": r"(?i)\birm\s+https?://",
    "iwr": r"(?i)\biwr\s+https?://",
    "curl": r"(?i)\bcurl(?:\.exe)?\b",
    "wget": r"(?i)\bwget(?:\.exe)?\b",
    "Start-BitsTransfer": r"\bStart-BitsTransfer\b",
    "HttpClient": r"System\.Net\.Http\.HttpClient|\bHttpClient\b",
    "WebClient": r"System\.Net\.WebClient|\bWebClient\b",
    "DownloadFile": r"\.DownloadFile\s*\(",
}

KEY_ENV_PREFIXES = (
    "HERMES_", "UV_", "NPM_", "PLAYWRIGHT_", "ELECTRON_",
    "AGENT_BROWSER_", "CSC_", "WIN_CSC_"
)

def strip_comments(text: str) -> str:
    text = re.sub(r"<#[\s\S]*?#>", "", text)
    kept = []
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            continue
        kept.append(line)
    return "\n".join(kept)

def quoted_setting(text: str, name: str):
    m = re.search(r"\$" + re.escape(name) + r"\s*=\s*[\"']([^\"']+)[\"']", text)
    return m.group(1) if m else None

def extract_contract(text: str):
    code = strip_comments(text)

    start = text.find(STAGE_START)
    end = text.find(STAGE_END, start + 1) if start >= 0 else -1
    stage_block = text[start:end] if start >= 0 and end > start else ""
    stages = re.findall(r"\bName\s*=\s*[\"']([^\"']+)[\"']", stage_block)

    funcs = sorted(set(re.findall(r"(?im)^\s*function\s+([A-Za-z0-9_-]+)\b", code)))

    fallback_m = re.search(r"\$PythonFallbackVersions\s*=\s*@\(([^)]*)\)", code)
    fallbacks = []
    if fallback_m:
        fallbacks = re.findall(r"[\"']([^\"']+)[\"']", fallback_m.group(1))

    hosts = sorted(set(
        h.lower() for h in re.findall(r"https?://([A-Za-z0-9.-]+)", code, flags=re.I)
    ))

    env_vars = sorted(set(
        name for name in re.findall(r"\$env:([A-Za-z0-9_]+)", code)
        if name.upper().startswith(KEY_ENV_PREFIXES)
    ), key=str.upper)

    network_primitives = sorted(
        name for name, pattern in NETWORK_PATTERNS.items()
        if re.search(pattern, code, flags=re.M)
    )

    managed_python = None
    m = re.search(
        r"\$managedRoot\s*=\s*Join-Path\s+\$InstallDir\s+[\"']([^\"']+)[\"']",
        code,
        flags=re.I,
    )
    if m:
        managed_python = m.group(1)

    managed_uv = None
    m = re.search(
        r"\$managedUv\s*=\s*Join-Path\s+\$HermesHome\s+[\"']([^\"']+)[\"']",
        code,
        flags=re.I,
    )
    if m:
        managed_uv = m.group(1)

    return {
        "stage_names": stages,
        "python_version": quoted_setting(code, "PythonVersion"),
        "python_fallback_versions": fallbacks,
        "node_major": quoted_setting(code, "NodeVersion"),
        "required_functions_present": funcs,
        "network_primitives": network_primitives,
        "url_hosts": hosts,
        "key_env_vars": env_vars,
        "managed_python_relative_path": managed_python,
        "managed_uv_relative_path": managed_uv,
        "stage_marker_present": STAGE_START in text,
    }

def compare(actual, expected):
    problems = []

    def exact(key, label=None):
        if actual.get(key) != expected.get(key):
            problems.append({
                "kind": "changed",
                "field": label or key,
                "expected": expected.get(key),
                "actual": actual.get(key),
            })

    for key, label in [
        ("stage_names", "stage list/order"),
        ("python_version", "Python policy"),
        ("python_fallback_versions", "Python fallback policy"),
        ("node_major", "Node major policy"),
        ("network_primitives", "network primitives"),
        ("url_hosts", "external URL hosts"),
        ("key_env_vars", "key runtime environment variables"),
        ("managed_python_relative_path", "managed Python location"),
        ("managed_uv_relative_path", "managed uv location"),
        ("stage_marker_present", "stage insertion marker"),
    ]:
        exact(key, label)

    missing = sorted(set(expected["required_functions"]) - set(actual["required_functions_present"]))
    if missing:
        problems.append({
            "kind": "missing",
            "field": "required upstream functions",
            "expected": expected["required_functions"],
            "actual": missing,
        })

    return problems

def md(value):
    if isinstance(value, list):
        return ", ".join(f"`{x}`" for x in value) if value else "_none_"
    if value is None:
        return "_missing_"
    return f"`{value}`"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--installer", required=True)
    ap.add_argument("--contract", required=True)
    ap.add_argument("--upstream-ref", required=True)
    ap.add_argument("--summary")
    args = ap.parse_args()

    installer = Path(args.installer).read_text(encoding="utf-8-sig")
    baseline = json.loads(Path(args.contract).read_text(encoding="utf-8"))
    actual = extract_contract(installer)
    expected = baseline["expected"]
    problems = compare(actual, expected)

    print(f"Upstream ref: {args.upstream_ref}")
    print(f"Accepted contract baseline: {baseline.get('accepted_from_upstream_ref', 'unknown')}")
    print(f"Stages: {actual['stage_names']}")
    print(f"Python: {actual['python_version']} fallbacks={actual['python_fallback_versions']}")
    print(f"Node major: {actual['node_major']}")
    print(f"Managed Python: {actual['managed_python_relative_path']}")
    print(f"Managed uv: {actual['managed_uv_relative_path']}")
    print(f"Network primitives: {actual['network_primitives']}")
    print(f"External URL hosts: {actual['url_hosts']}")
    print(f"Key env vars: {actual['key_env_vars']}")

    status = "PASS" if not problems else "BLOCK"
    lines = [
        "## Hermes installer contract gate",
        "",
        f"**Status:** {status}",
        f"**Upstream:** `{args.upstream_ref}`",
        f"**Accepted baseline:** `{baseline.get('accepted_from_upstream_ref', 'unknown')}`",
        "",
        f"- Stages: {md(actual['stage_names'])}",
        f"- Python: {md(actual['python_version'])}; fallbacks: {md(actual['python_fallback_versions'])}",
        f"- Node major: {md(actual['node_major'])}",
        f"- Managed Python: {md(actual['managed_python_relative_path'])}",
        f"- Managed uv: {md(actual['managed_uv_relative_path'])}",
        f"- Network primitives: {md(actual['network_primitives'])}",
        f"- URL hosts: {md(actual['url_hosts'])}",
        f"- Key env vars: {md(actual['key_env_vars'])}",
    ]

    if problems:
        lines += ["", "### Contract changes requiring review"]
        for p in problems:
            lines.append(f"- **{p['field']}**: expected {md(p['expected'])}; actual {md(p['actual'])}")
        print("Installer contract changed; refusing to dispatch the heavy Windows build.", file=sys.stderr)
        for p in problems:
            print(json.dumps(p, ensure_ascii=False), file=sys.stderr)
    else:
        lines += ["", "No reviewed installer-contract assumptions changed. Windows validation may proceed."]

    if args.summary:
        Path(args.summary).write_text("\n".join(lines) + "\n", encoding="utf-8")

    print(json.dumps({"status": status, "actual": actual, "problems": problems}, ensure_ascii=False))
    return 0 if not problems else 42

if __name__ == "__main__":
    raise SystemExit(main())
