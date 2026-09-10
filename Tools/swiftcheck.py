#!/usr/bin/env python3
"""Static consistency checker for the Dubplate Swift sources.

Dubplate is an Apple-platform application, so the authoritative check is
`xcodebuild` on macOS. This tool exists so that the source tree can still be
verified for whole-program consistency on a machine without an Apple toolchain,
and so CI can catch a useful class of mistakes quickly:

  * unbalanced braces / parens / brackets (per file)
  * duplicate type declarations inside a module
  * `import` of a module the target does not depend on
  * capitalised identifiers that resolve to no declaration and no known
    platform type (catches typos and renames across ~100 files)
  * SwiftData + CloudKit model rules: stored properties must be optional or
    carry a default, relationships must be optional, `.unique` is forbidden
  * house style: force unwraps, `try!`, `print(`, oversized files

Run:  python3 Tools/swiftcheck.py [--quiet]
Exit code is non-zero when an error-level finding is present.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ALLOWLIST_PATH = os.path.join(ROOT, "Tools", "platform-symbols.json")

MAX_FILE_LINES = 520


# ---------------------------------------------------------------- tokenising


def strip_noise(src: str) -> str:
    """Replace comments and string literal bodies with spaces.

    Newlines are preserved so that line numbers stay accurate.
    """
    out = []
    i = 0
    n = len(src)
    block_depth = 0
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""

        if block_depth:
            if c == "/" and nxt == "*":
                block_depth += 1
                out.append("  ")
                i += 2
                continue
            if c == "*" and nxt == "/":
                block_depth -= 1
                out.append("  ")
                i += 2
                continue
            out.append("\n" if c == "\n" else " ")
            i += 1
            continue

        if c == "/" and nxt == "*":
            block_depth = 1
            out.append("  ")
            i += 2
            continue

        if c == "/" and nxt == "/":
            while i < n and src[i] != "\n":
                out.append(" ")
                i += 1
            continue

        # Raw string delimiters: #"..."#  or  ##"""..."""##
        hashes = 0
        j = i
        while j < n and src[j] == "#":
            hashes += 1
            j += 1
        if hashes and j < n and src[j] == '"':
            i, chunk = _consume_string(src, j, hashes)
            out.append(" " * hashes + chunk)
            continue

        if c == '"':
            i, chunk = _consume_string(src, i, 0)
            out.append(chunk)
            continue

        out.append(c)
        i += 1
    return "".join(out)


def _consume_string(src: str, i: int, hashes: int) -> tuple[int, str]:
    """Consume a string literal starting at src[i] == '"'. Returns (index, blanked).

    Interpolations are consumed too, including strings nested inside them — a title
    like "Delete \\(name.isEmpty ? "Untitled" : name)?" would otherwise end the
    string at the inner quote and leave `Untitled` looking like code.
    """
    n = len(src)
    closing_hashes = "#" * hashes
    multiline = src.startswith('"""', i)
    quote = '"""' if multiline else '"'
    out = [" " * len(quote)]
    i += len(quote)
    escape = "\\" + closing_hashes

    while i < n:
        if src.startswith(escape + "(", i):
            # An interpolation: skip to its matching ')', respecting nested strings.
            out.append(" " * (len(escape) + 1))
            i += len(escape) + 1
            depth = 1
            while i < n and depth > 0:
                if src[i] == '"':
                    i, chunk = _consume_string(src, i, 0)
                    out.append(chunk)
                    continue
                if src[i] == "(":
                    depth += 1
                elif src[i] == ")":
                    depth -= 1
                out.append("\n" if src[i] == "\n" else " ")
                i += 1
            continue
        if src.startswith(escape, i):
            out.append(" " * (len(escape) + 1))
            i += len(escape) + 1
            continue
        if src.startswith(quote + closing_hashes, i):
            out.append(" " * (len(quote) + hashes))
            i += len(quote) + hashes
            break
        out.append("\n" if src[i] == "\n" else " ")
        i += 1
    return i, "".join(out)


# ---------------------------------------------------------------- model


@dataclass
class Finding:
    level: str  # "error" | "warn"
    path: str
    line: int
    rule: str
    message: str


@dataclass
class Module:
    name: str
    path: str
    deps: list[str] = field(default_factory=list)
    files: list[str] = field(default_factory=list)
    declarations: dict[str, tuple[str, int, frozenset]] = field(default_factory=dict)
    resolvable: set[str] = field(default_factory=set)


DECL_RE = re.compile(
    r"(?m)^[ \t]*(?:@[\w.()\[\], :\"]+[ \t]*)*"
    r"(?:public |internal |private |fileprivate |package |open |final |indirect |@objc )*"
    r"\b(struct|class|enum|protocol|actor|typealias)\s+([A-Z][A-Za-z0-9_]*)"
)
EXT_RE = re.compile(r"(?m)^[ \t]*(?:public |private |fileprivate |package )*extension\s+([A-Za-z0-9_.]+)")
IMPORT_RE = re.compile(r"(?m)^[ \t]*(?:@\w+\s+)?import\s+(?:struct |class |enum |func |protocol |typealias )?([A-Za-z0-9_.]+)")
IDENT_RE = re.compile(r"(?<![\.\w$@])([A-Z][A-Za-z0-9_]*)")
GENERIC_PARAM_RE = re.compile(r"(?:struct|class|enum|func|actor)\s+\w+\s*<([^>]*)>")


def load_allowlist() -> set[str]:
    with open(ALLOWLIST_PATH, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    names: set[str] = set()
    for key, group in data.items():
        if key.startswith("_"):
            continue
        names.update(group)
    return names


def discover_modules() -> list[Module]:
    manifest_path = os.path.join(ROOT, "Package.swift")
    # Read raw: strip_noise() would blank the string literals we need here.
    manifest = open(manifest_path, encoding="utf-8").read()
    modules: list[Module] = []
    for match in re.finditer(
        r"\.(?:target|testTarget)\(\s*name:\s*\"(\w+)\"(.*?)path:\s*\"([^\"]+)\"",
        manifest,
        re.S,
    ):
        name, body, path = match.group(1), match.group(2), match.group(3)
        deps = re.findall(r"\"(\w+)\"", body)
        modules.append(Module(name=name, path=path, deps=deps))
    # The two application targets are Xcode targets, not SPM targets.
    modules.append(Module(name="DubplateMac", path="Apps/DubplateMac",
                          deps=["DubplateCore", "DubplateAudio", "DubplateSync", "DubplateUI"]))
    modules.append(Module(name="DubplateiOS", path="Apps/DubplateiOS",
                          deps=["DubplateCore", "DubplateAudio", "DubplateSync", "DubplateUI"]))
    modules.append(Module(name="UITests", path="Tests/UITests", deps=[]))
    for module in modules:
        base = os.path.join(ROOT, module.path)
        for dirpath, _dirs, files in os.walk(base):
            for name in sorted(files):
                if name.endswith(".swift"):
                    module.files.append(os.path.join(dirpath, name))
        module.files.sort()
    return modules


def rel(path: str) -> str:
    return os.path.relpath(path, ROOT)


# ---------------------------------------------------------------- checks


def check_balance(path: str, code: str, findings: list[Finding]) -> None:
    pairs = {")": "(", "]": "[", "}": "{"}
    stack: list[tuple[str, int]] = []
    line = 1
    for ch in code:
        if ch == "\n":
            line += 1
        elif ch in "([{":
            stack.append((ch, line))
        elif ch in ")]}":
            if not stack or stack[-1][0] != pairs[ch]:
                findings.append(Finding("error", rel(path), line, "balance",
                                        f"unbalanced '{ch}'"))
                return
            stack.pop()
    if stack:
        ch, line = stack[-1]
        findings.append(Finding("error", rel(path), line, "balance",
                                f"'{ch}' opened here is never closed"))


def branch_signatures(code: str) -> list[frozenset]:
    """Signature per line describing which #if branch that line sits in.

    Two declarations of the same name are only a real clash when they can both be
    compiled: a `#if os(iOS)` typealias and its `#else` twin cannot.
    """
    signatures: list[frozenset] = []
    stack: list[tuple[int, int]] = []
    block_id = 0
    for line in code.split("\n"):
        stripped = line.strip()
        if stripped.startswith("#if"):
            block_id += 1
            stack.append((block_id, 0))
        elif stripped.startswith("#elseif") or stripped.startswith("#else"):
            if stack:
                current, branch = stack[-1]
                stack[-1] = (current, branch + 1)
        elif stripped.startswith("#endif"):
            if stack:
                stack.pop()
        signatures.append(frozenset(stack))
    return signatures


def mutually_exclusive(lhs: frozenset, rhs: frozenset) -> bool:
    left = dict(lhs)
    for block, branch in rhs:
        if block in left and left[block] != branch:
            return True
    return False


def collect_declarations(module: Module, sources: dict[str, str], findings: list[Finding]) -> None:
    """Index every declaration, qualifying nested types by their enclosing type.

    `DubplateError.Kind` and `SearchResult.Kind` are different types; only a clash
    on the fully qualified name is a real duplicate.
    """
    for path in module.files:
        code = sources[path]
        signatures = branch_signatures(code)
        stack: list[tuple[str, int]] = []
        for match in DECL_RE.finditer(code):
            name = match.group(2)
            prefix = code[: match.start()]
            depth = prefix.count("{") - prefix.count("}")
            line = prefix.count("\n") + 1
            while stack and stack[-1][1] >= depth:
                stack.pop()
            qualified = ".".join([entry[0] for entry in stack] + [name])
            if match.group(1) != "typealias":
                stack.append((name, depth))
            module.resolvable.add(name)
            signature = signatures[line - 1] if line - 1 < len(signatures) else frozenset()
            if qualified in module.declarations:
                prev_path, prev_line, prev_signature = module.declarations[qualified]
                if not (prev_path == rel(path) and mutually_exclusive(prev_signature, signature)):
                    findings.append(Finding(
                        "error", rel(path), line, "duplicate-decl",
                        f"'{qualified}' is already declared at {prev_path}:{prev_line}"))
            else:
                module.declarations[qualified] = (rel(path), line, signature)


def check_imports(module: Module, sources: dict[str, str], first_party: set[str],
                  allow: set[str], findings: list[Finding]) -> None:
    for path in module.files:
        code = sources[path]
        for match in IMPORT_RE.finditer(code):
            name = match.group(1).split(".")[0]
            line = code[: match.start()].count("\n") + 1
            if name in first_party:
                if name != module.name and name not in module.deps:
                    findings.append(Finding(
                        "error", rel(path), line, "import-dependency",
                        f"module '{module.name}' imports '{name}' but does not depend on it"))
            elif name not in allow:
                findings.append(Finding(
                    "warn", rel(path), line, "unknown-import",
                    f"'{name}' is not a known platform module"))


def visible_names(module: Module, modules: dict[str, Module], sources: dict[str, str]) -> set[str]:
    names = set(module.resolvable)
    for dep in module.deps:
        if dep in modules:
            names |= modules[dep].resolvable
    return names


def check_type_references(module: Module, modules: dict[str, Module], sources: dict[str, str],
                          allow: set[str], findings: list[Finding]) -> None:
    known = visible_names(module, modules, sources) | allow
    for path in module.files:
        # Import lines are validated by check_imports; blank them so a module name
        # is not mistaken for a type reference.
        code = IMPORT_RE.sub(lambda m: " " * len(m.group(0)), sources[path])
        local = set()
        for match in GENERIC_PARAM_RE.finditer(code):
            for part in match.group(1).split(","):
                token = part.strip().split(":")[0].strip()
                if token:
                    local.add(token)
        # Names introduced only by an extension of a platform type still count.
        for match in EXT_RE.finditer(code):
            local.add(match.group(1).split(".")[0])
        for match in IDENT_RE.finditer(code):
            name = match.group(1)
            if name in known or name in local:
                continue
            line = code[: match.start()].count("\n") + 1
            findings.append(Finding(
                "error", rel(path), line, "unknown-type",
                f"'{name}' does not resolve to a declaration in {module.name}, "
                f"its dependencies, or the platform allowlist"))


MODEL_BLOCK_RE = re.compile(r"(?m)^@Model\b")
PROPERTY_RE = re.compile(
    r"(?m)^[ \t]*(?:@\w+(?:\([^)]*\))?[ \t]*)*(?:public |private |internal |package )?"
    r"var\s+(\w+)\s*:\s*([^\n=]+?)(\s*=\s*|$)"
)


def check_swiftdata_models(module: Module, sources: dict[str, str], findings: list[Finding]) -> None:
    for path in module.files:
        code = sources[path]
        for match in MODEL_BLOCK_RE.finditer(code):
            start = code.index("{", match.end())
            depth = 0
            end = start
            for idx in range(start, len(code)):
                if code[idx] == "{":
                    depth += 1
                elif code[idx] == "}":
                    depth -= 1
                    if depth == 0:
                        end = idx
                        break
            body = code[start:end]
            offset = code[:start].count("\n") + 1
            if ".unique" in body:
                findings.append(Finding(
                    "error", rel(path), offset, "cloudkit-unique",
                    "@Attribute(.unique) is not supported by CloudKit mirroring"))
            if re.search(r"deleteRule:\s*\.deny", body):
                findings.append(Finding(
                    "error", rel(path), offset, "cloudkit-delete-rule",
                    ".deny delete rules are not supported by CloudKit mirroring"))
            check_relationship_inverses(body, rel(path), offset, findings)
            for prop in PROPERTY_RE.finditer(body):
                name, type_text, tail = prop.group(1), prop.group(2).strip(), prop.group(3)
                line = offset + body[: prop.start()].count("\n")
                if "{" in type_text or "@Transient" in prop.group(0):
                    continue  # computed or non-persisted
                optional = type_text.endswith("?") or type_text.startswith("Optional")
                defaulted = "=" in tail
                if not optional and not defaulted:
                    findings.append(Finding(
                        "error", rel(path), line, "cloudkit-default",
                        f"'{name}: {type_text}' must be optional or carry a default "
                        "for CloudKit mirroring"))


# Modifiers may carry an access-level argument — `public private(set) var x` — which
# an alternation of bare words silently skips, leaving the property invisible to
# every rule that asks what a type declares.
MEMBER_MODIFIERS = (
    r"(?:(?:public|private|fileprivate|internal|package|open|static|class|final"
    r"|override|mutating|nonisolated|convenience|lazy|weak|unowned|dynamic)"
    r"(?:\((?:set|get|unsafe|safe)\))?[ \t]+)*"
)
MEMBER_FUNC_RE = re.compile(
    r"(?m)^[ \t]*(?:@\w+(?:\([^)]*\))?[ \t]*)*" + MEMBER_MODIFIERS + r"func\s+(\w+)\s*[(<]"
)
MEMBER_VAR_RE = re.compile(
    r"(?m)^[ \t]*(?:@\w+(?:\([^)]*\))?[ \t]*)*" + MEMBER_MODIFIERS + r"(?:var|let)\s+(\w+)"
)
BARE_CALL_RE = re.compile(r"(?<![\.\w$])([a-z_][A-Za-z0-9_]*)\s*\(")

SWIFT_GLOBAL_FUNCTIONS = {
    "min", "max", "abs", "sqrt", "sin", "cos", "tan", "atan", "atan2", "exp",
    "log", "log2", "log10", "pow", "round", "ceil", "floor", "swap", "zip",
    "stride", "type", "print", "dump", "assert", "assertionFailure", "precondition",
    "preconditionFailure", "fatalError", "withAnimation", "withTransaction",
    "withUnsafeBytes", "withUnsafePointer", "withUnsafeMutableBytes",
    "unsafeBitCast", "sequence", "repeatElement", "isKnownUniquelyReferenced",
    "withCheckedContinuation", "withCheckedThrowingContinuation", "withTaskGroup",
    "withThrowingTaskGroup", "withTaskCancellationHandler", "autoreleasepool",
    "getter", "setter", "if", "guard", "while", "for", "switch", "return", "catch",
    "init", "deinit", "super", "self", "throw", "try", "await", "async", "in",
    "where", "case", "default", "do", "else", "repeat", "defer",
    # `let (a, b) = …` destructuring, and the compiler directives.
    "let", "var", "os", "canImport", "swift", "compiler", "targetEnvironment", "arch",
    "_",
    # `public private(set) var …` and friends.
    "private", "fileprivate", "internal", "public", "package", "open",
    "nonisolated", "unsafe", "set", "get", "willSet", "didSet", "some", "any",
}
SELF_MEMBER_RE = re.compile(r"\bself\??\.([a-zA-Z_][A-Za-z0-9_]*)")
# `isTransferring = active` on its own line, where nothing declares isTransferring.
BARE_ASSIGN_RE = re.compile(r"(?m)^[ \t]+([a-z_][A-Za-z0-9_]*)\s*(?:=|\+=|-=)\s*[^=]")


def check_own_members(module: Module, sources: dict[str, str], allow: set[str],
                      findings: list[Finding]) -> None:
    """Resolve calls a type makes on itself against what it actually declares.

    This is the check that catches a method that was renamed, never written, or
    lost to a bad patch — the class of mistake that looks fine in review and fails
    at the first build. Only types that inherit nothing are checked, because a
    subclass can legitimately call something it did not declare.
    """
    for path in module.files:
        code = sources[path]
        for match in DECL_RE.finditer(code):
            kind, name = match.group(1), match.group(2)
            if kind not in {"struct", "enum", "actor", "class"}:
                continue
            header_end = code.find("{", match.end())
            if header_end == -1:
                continue
            header = code[match.end():header_end]
            # `: SomeProtocol` is fine; `: SomeClass` may bring inherited members,
            # and a non-final class may be subclassed. Skip anything not obviously
            # self-contained.
            # A non-final class may be subclassed, and a subclass legitimately uses
            # members it did not declare. The modifiers are part of the match.
            if kind == "class" and "final" not in match.group(0):
                continue
            if ":" in header:
                continue

            depth = 0
            end = header_end
            for index in range(header_end, len(code)):
                if code[index] == "{":
                    depth += 1
                elif code[index] == "}":
                    depth -= 1
                    if depth == 0:
                        end = index
                        break
            body = code[header_end:end]
            offset = code[:header_end].count("\n") + 1

            declared = set(MEMBER_FUNC_RE.findall(body)) | set(MEMBER_VAR_RE.findall(body))
            # Extensions of the same type, anywhere in the module, count too.
            for other in module.files:
                other_code = sources[other]
                for extension in re.finditer(
                    r"(?m)^[ \t]*(?:public |private |fileprivate |package )*extension\s+"
                    + re.escape(name) + r"\b", other_code
                ):
                    start = other_code.find("{", extension.end())
                    if start == -1:
                        continue
                    inner_depth = 0
                    stop = start
                    for index in range(start, len(other_code)):
                        if other_code[index] == "{":
                            inner_depth += 1
                        elif other_code[index] == "}":
                            inner_depth -= 1
                            if inner_depth == 0:
                                stop = index
                                break
                    section = other_code[start:stop]
                    declared |= set(MEMBER_FUNC_RE.findall(section))
                    declared |= set(MEMBER_VAR_RE.findall(section))

            # Anything bound anywhere in the body — including a local `let` holding
            # a closure — counts as declared, which keeps this quiet enough to trust.
            declared |= set(re.findall(r"\b(?:let|var)\s+(\w+)", body))
            declared |= set(re.findall(r"\bcase\s+(\w+)", body))
            declared |= set(re.findall(r"(\w+)\s*:\s*[A-Za-z_(\[]", body))

            for reference in SELF_MEMBER_RE.finditer(body):
                member = reference.group(1)
                if member in declared or member in allow:
                    continue
                line = offset + body[: reference.start()].count("\n")
                findings.append(Finding(
                    "error", rel(path), line, "unknown-member",
                    f"'{name}' has no member '{member}'"))

            for reference in BARE_ASSIGN_RE.finditer(body):
                assigned = reference.group(1)
                if assigned in declared or assigned in allow or assigned in SWIFT_GLOBAL_FUNCTIONS:
                    continue
                line = offset + body[: reference.start()].count("\n")
                findings.append(Finding(
                    "error", rel(path), line, "unknown-member",
                    f"'{name}' assigns '{assigned}', which it does not declare"))

            for reference in BARE_CALL_RE.finditer(body):
                called = reference.group(1)
                if called in declared or called in allow or called in SWIFT_GLOBAL_FUNCTIONS:
                    continue
                line = offset + body[: reference.start()].count("\n")
                findings.append(Finding(
                    "error", rel(path), line, "unknown-member",
                    f"'{name}' calls '{called}()', which it does not declare"))


SELF_CAPTURE_RE = re.compile(r"\{\s*\[\s*(?:weak\s+|unowned\s+)?self\s*\]")
LOCAL_BINDING_RE = re.compile(r"\b(?:let|var)\s+([a-z]\w*)")
CLOSURE_PARAMS_RE = re.compile(r"^\s*\[[^\]]*\]\s*([^\n]*?)\s+in\b")


def check_explicit_self(module: Module, sources: dict[str, str], findings: list[Finding]) -> None:
    """Inside a closure that captures self, members must be written `self.member`.

    `guard let self` unwraps self for the statements after it — not for the guard's
    own condition, and not for another escaping closure created inside the body.
    Which of those applies where is subtle enough that the rule here is the blunt
    one: in a closure that captures self, spell it out.
    """
    for path in module.files:
        code = sources[path]
        for match in DECL_RE.finditer(code):
            if match.group(1) not in {"class", "actor"}:
                continue
            header_end = code.find("{", match.end())
            if header_end == -1:
                continue
            depth, end = 0, header_end
            for index in range(header_end, len(code)):
                if code[index] == "{":
                    depth += 1
                elif code[index] == "}":
                    depth -= 1
                    if depth == 0:
                        end = index
                        break
            body = code[header_end:end]
            declared = set(MEMBER_FUNC_RE.findall(body)) | set(MEMBER_VAR_RE.findall(body))
            if not declared:
                continue

            for capture in SELF_CAPTURE_RE.finditer(body):
                brace = body.find("{", capture.start())
                depth, closing = 0, brace
                for index in range(brace, len(body)):
                    if body[index] == "{":
                        depth += 1
                    elif body[index] == "}":
                        depth -= 1
                        if depth == 0:
                            closing = index
                            break
                closure = body[brace:closing]
                # Names bound inside the closure shadow the members they match.
                shadowed = set(LOCAL_BINDING_RE.findall(closure))
                parameters = CLOSURE_PARAMS_RE.search(closure[1:200] or "")
                if parameters:
                    shadowed |= set(re.findall(r"[a-z]\w*", parameters.group(1)))
                # A member is used by reading it, calling it, or assigning to it.
                # `==` and `!=` are comparisons, not assignments.
                for use in re.finditer(r"(?<![\w.$?!<>=+\-*/])([a-z]\w*)\s*(?:[.(]|=(?!=))", closure):
                    word = use.group(1)
                    if word not in declared or word in shadowed:
                        continue
                    line = code[:header_end].count("\n") + closure[: use.start()].count("\n") \
                        + body[:brace].count("\n") + 1
                    findings.append(Finding(
                        "error", rel(path), line, "implicit-self",
                        f"'{word}' is used without `self.` inside a closure that captures self"))


LOG_CALL_RE = re.compile(
    r"Log\.[a-z]+\.(?:error|info|debug|notice|warning|fault|log|critical|trace)\s*\("
)


def check_log_messages(body: str, path: str, offset: int, findings: list[Finding]) -> None:
    """A Logger message is one literal, never two joined by `+`.

    `Logger.error(_:)` takes an `OSLogMessage`, which the compiler assembles from a
    single interpolated literal so each value can carry its own privacy annotation.
    Two of them cannot be concatenated, and reaching for `+` to wrap a long line is
    the obvious thing to do — so it is the obvious thing to catch.
    """
    for match in LOG_CALL_RE.finditer(body):
        depth, index = 0, match.end() - 1
        while index < len(body):
            character = body[index]
            if character == "(":
                depth += 1
            elif character == ")":
                depth -= 1
                if depth == 0:
                    break
            index += 1
        argument = body[match.end():index]
        if re.search(r'"\s*\n\s*\+|\+\s*"', argument):
            line = offset + body[: match.start()].count("\n")
            findings.append(Finding(
                "error", rel(path), line, "log-concatenation",
                "a Logger message is one literal; `+` cannot join two OSLogMessages"))


# Methods that read like the standard library and are not: SwiftUI adds each of
# these in an extension, so they exist in a file that imports SwiftUI and nowhere
# else. Used in a module that has no business importing a UI framework, they
# compile in the editor's imagination and fail on the build.
SWIFTUI_ONLY_MEMBERS = {
    "move(fromOffsets:": "SwiftUI's extension on RangeReplaceableCollection",
    "remove(atOffsets:": "SwiftUI's extension on RangeReplaceableCollection",
}


def check_swiftui_only_members(module, sources: dict[str, str],
                               findings: list[Finding]) -> None:
    """Flags SwiftUI-only collection helpers in a module that does not import it."""
    for path in module.files:
        code = sources[path]
        if re.search(r"^\s*import\s+SwiftUI\b", code, re.M):
            continue
        for needle, origin in SWIFTUI_ONLY_MEMBERS.items():
            start = 0
            while True:
                found = code.find("." + needle, start)
                if found < 0:
                    break
                line = code[:found].count("\n") + 1
                findings.append(Finding(
                    "error", rel(path), line, "swiftui-only",
                    f"'{needle}…)' comes from {origin}, and this file does not import SwiftUI"))
                start = found + 1


ENVIRONMENT_USE_RE = re.compile(r"@Environment\(\s*([A-Z][A-Za-z0-9_]*)\.self\s*\)")
ENVIRONMENT_INJECT_RE = re.compile(r"\.environment\(\s*([A-Za-z0-9_.]+)")
OBSERVABLE_CLASS_RE = re.compile(
    r"@Observable[\s\S]{0,200}?\b(?:final\s+)?class\s+([A-Z][A-Za-z0-9_]*)"
)


def check_environment_objects(modules: list[Module], sources: dict[str, str],
                              findings: list[Finding]) -> None:
    """Every `@Environment(X.self)` needs an `.environment(…)` that supplies an X.

    A missing injection is not a compile error — it is a crash the first time the
    view appears, which is exactly the kind of thing that survives a code review and
    does not survive a demo.

    Checked per application, because the shared views in DubplateUI are hosted by
    both: an object injected by the Mac and forgotten by the phone would otherwise
    look fine.
    """
    aliases = {
        "AppServices": {"services"},
        "LibraryStore": {"library"},
        "PlayerController": {"player"},
        "ArtworkLoader": {"artwork"},
        "SyncCoordinator": {"sync"},
        "DubplateSettings": {"settings"},
    }

    def injections(module: Module) -> set[str]:
        found: set[str] = set()
        for path in module.files:
            for match in ENVIRONMENT_INJECT_RE.finditer(sources[path]):
                # Without type inference the property name is the only clue, so both
                # the expression's last component and its capitalised form count.
                leaf = match.group(1).split(".")[-1]
                found.add(leaf)
                found.add(leaf[:1].upper() + leaf[1:])
        return found

    def uses(module: Module) -> list[tuple[str, str, int]]:
        found = []
        for path in module.files:
            code = sources[path]
            for match in ENVIRONMENT_USE_RE.finditer(code):
                found.append((match.group(1), path, code[: match.start()].count("\n") + 1))
        return found

    by_name = {m.name: m for m in modules}
    shared = by_name.get("DubplateUI")

    # Anything handed to `.environment(x)` must be @Observable: the object overload
    # requires the conformance, and a class that merely looks like the five beside
    # it compiles everywhere except the one line that injects it.
    observable: set[str] = set()
    for module in modules:
        for path in module.files:
            for match in OBSERVABLE_CLASS_RE.finditer(sources[path]):
                observable.add(match.group(1))
    for name, aliased in aliases.items():
        if name in observable:
            continue
        for module in modules:
            for path in module.files:
                for match in ENVIRONMENT_INJECT_RE.finditer(sources[path]):
                    leaf = match.group(1).split(".")[-1]
                    if leaf not in aliased and leaf != name[:1].lower() + name[1:]:
                        continue
                    line = sources[path][: match.start()].count("\n") + 1
                    findings.append(Finding(
                        "error", rel(path), line, "environment-observable",
                        f"'{name}' is injected into the environment but is not @Observable"))

    for app_name in ["DubplateMac", "DubplateiOS"]:
        app = by_name.get(app_name)
        if app is None:
            continue
        supplied = injections(app)
        if shared is not None:
            supplied |= injections(shared)
        required = uses(app) + (uses(shared) if shared is not None else [])
        for name, path, line in required:
            candidates = {name, name[:1].lower() + name[1:]} | aliases.get(name, set())
            if candidates & supplied:
                continue
            findings.append(Finding(
                "error", rel(path), line, "environment",
                f"@Environment({name}.self) is read but {app_name} injects no {name}"))


RELATIONSHIP_RE = re.compile(
    r"@Relationship\(([^)]*)\)\s*(?:public |private |internal |package )?var\s+(\w+)\s*:\s*([^\n=]+)"
)


def check_relationship_inverses(body: str, path: str, offset: int, findings: list[Finding]) -> None:
    """CloudKit mirroring refuses a model with a relationship that has no inverse.

    The failure is a store that will not open, which the fallback path then turns
    into a silent downgrade to a local-only library — the worst possible shape for
    this particular bug, because everything appears to work and nothing syncs.

    An inverse may be declared on either side, so this only reports a relationship
    whose *type* is never mentioned in any `inverse:` key path anywhere in the
    module. That is coarse, and it catches the case that matters.
    """
    for match in RELATIONSHIP_RE.finditer(body):
        arguments, name, type_text = match.group(1), match.group(2), match.group(3).strip()
        line = offset + body[: match.start()].count("\n")
        if "inverse:" in arguments:
            continue
        target = type_text.strip("[]?").split("<")[-1].strip("> ")
        findings.append(Finding(
            "warn", path, line, "relationship-inverse",
            f"'{name}: {type_text}' declares no inverse; confirm one is declared on "
            f"{target}, or CloudKit mirroring will refuse the model"))


STYLE_RULES = [
    (re.compile(r"(?<![\w\"!?])try!"), "force-try", "warn", "`try!` — prefer explicit handling"),
    (re.compile(r"\bas!\s"), "force-cast", "warn", "`as!` — prefer conditional cast"),
    (re.compile(r"(?m)^[ \t]*print\("), "print", "warn", "use Log instead of print()"),
    (re.compile(r"\bfatalError\("), "fatal-error", "warn", "fatalError in shipping code"),
]
FORCE_UNWRAP_RE = re.compile(r"(?<![=!<>+\-*/%&|^\s(,\[{])!(?![=&|])")
# `var store: LibraryStore!` is an implicitly-unwrapped declaration, not a force
# unwrap; XCTestCase properties set up in setUp() are written this way by convention.
IUO_DECLARATION_RE = re.compile(r":\s*[A-Za-z0-9_.<>\[\]?]+!\s*(//.*)?$")


def check_style(module: Module, sources: dict[str, str], findings: list[Finding]) -> None:
    for path in module.files:
        code = sources[path]
        raw_lines = open(path, encoding="utf-8").read().split("\n")
        if len(raw_lines) > MAX_FILE_LINES:
            findings.append(Finding("warn", rel(path), len(raw_lines), "file-length",
                                    f"{len(raw_lines)} lines exceeds {MAX_FILE_LINES}"))
        for regex, rule, level, message in STYLE_RULES:
            for match in regex.finditer(code):
                line = code[: match.start()].count("\n") + 1
                if "swiftcheck:allow" in raw_lines[line - 1]:
                    continue
                findings.append(Finding(level, rel(path), line, rule, message))
        for idx, text in enumerate(code.split("\n"), start=1):
            stripped = text.strip()
            if stripped.startswith("//"):
                continue
            if IUO_DECLARATION_RE.search(text):
                continue
            for match in FORCE_UNWRAP_RE.finditer(text):
                snippet = text[max(0, match.start() - 24):match.start() + 1].strip()
                if "swiftcheck:allow" in raw_lines[idx - 1]:
                    continue
                findings.append(Finding("warn", rel(path), idx, "force-unwrap",
                                        f"force unwrap: …{snippet}"))


# ---------------------------------------------------------------- driver


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--quiet", action="store_true")
    parser.add_argument("--rule", action="append", default=[],
                        help="only report these rules")
    args = parser.parse_args()

    allow = load_allowlist()
    modules = discover_modules()
    by_name = {m.name: m for m in modules}
    first_party = {m.name for m in modules}
    findings: list[Finding] = []

    sources: dict[str, str] = {}
    for module in modules:
        for path in module.files:
            code = strip_noise(open(path, encoding="utf-8").read())
            sources[path] = code
            check_balance(path, code, findings)

    for module in modules:
        collect_declarations(module, sources, findings)
    for module in modules:
        for path in module.files:
            # The raw file, not `sources`: `strip_noise` blanks string literals,
            # and the literals are the whole point of this one.
            check_log_messages(open(path, encoding="utf-8").read(), path, 1, findings)
    for module in modules:
        check_explicit_self(module, sources, findings)
    check_environment_objects(modules, sources, findings)
    for module in modules:
        check_swiftui_only_members(module, sources, findings)
    for module in modules:
        check_own_members(module, sources, allow, findings)
    for module in modules:
        check_imports(module, sources, first_party, allow, findings)
        check_type_references(module, by_name, sources, allow, findings)
        check_swiftdata_models(module, sources, findings)
        check_style(module, sources, findings)

    if args.rule:
        findings = [f for f in findings if f.rule in args.rule]

    errors = [f for f in findings if f.level == "error"]
    warns = [f for f in findings if f.level == "warn"]

    by_rule: dict[str, list[Finding]] = defaultdict(list)
    for finding in findings:
        by_rule[finding.rule].append(finding)

    if not args.quiet:
        for finding in sorted(findings, key=lambda f: (f.level != "error", f.rule, f.path, f.line)):
            print(f"{finding.level:5} {finding.path}:{finding.line}: [{finding.rule}] {finding.message}")
        print()

    total_files = sum(len(m.files) for m in modules)
    total_lines = sum(open(p, encoding="utf-8").read().count("\n") + 1 for p in sources)
    print(f"swiftcheck: {total_files} files, {total_lines} lines, "
          f"{len(errors)} errors, {len(warns)} warnings")
    for rule, items in sorted(by_rule.items(), key=lambda kv: -len(kv[1])):
        print(f"    {rule}: {len(items)}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
