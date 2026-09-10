#!/usr/bin/env python3
"""Validates Apps/Dubplate.xcodeproj/project.pbxproj without Xcode.

Parses the OpenStep property list, then checks the things that actually break a
project: a syntax error, a reference to an object that does not exist, a file
reference pointing at a path that is not on disk, a target missing a build phase,
or a build file whose fileRef is not in any group.

Run: python3 Tools/pbxcheck.py
"""

from __future__ import annotations

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBXPROJ = os.path.join(ROOT, "Apps", "Dubplate.xcodeproj", "project.pbxproj")


class Parser:
    """A small OpenStep plist reader — enough for a pbxproj, and no more."""

    def __init__(self, text: str):
        self.text = text
        self.index = 0

    def parse(self):
        self.skip()
        value = self.parse_value()
        self.skip()
        return value

    def skip(self):
        while self.index < len(self.text):
            character = self.text[self.index]
            if character in " \t\n\r":
                self.index += 1
            elif self.text.startswith("//", self.index):
                end = self.text.find("\n", self.index)
                self.index = len(self.text) if end == -1 else end
            elif self.text.startswith("/*", self.index):
                end = self.text.find("*/", self.index)
                if end == -1:
                    raise SyntaxError(f"unterminated comment at {self.line()}")
                self.index = end + 2
            else:
                return

    def line(self) -> int:
        return self.text.count("\n", 0, self.index) + 1

    def parse_value(self):
        character = self.text[self.index]
        if character == "{":
            return self.parse_dict()
        if character == "(":
            return self.parse_array()
        if character == '"':
            return self.parse_quoted()
        return self.parse_bare()

    def parse_dict(self):
        result = {}
        self.index += 1
        while True:
            self.skip()
            if self.index >= len(self.text):
                raise SyntaxError("unterminated dictionary")
            if self.text[self.index] == "}":
                self.index += 1
                return result
            key = self.parse_value()
            self.skip()
            if self.text[self.index] != "=":
                raise SyntaxError(f"expected '=' after {key!r} at line {self.line()}")
            self.index += 1
            self.skip()
            value = self.parse_value()
            self.skip()
            if self.index < len(self.text) and self.text[self.index] == ";":
                self.index += 1
            else:
                raise SyntaxError(f"expected ';' after {key!r} at line {self.line()}")
            result[key] = value

    def parse_array(self):
        result = []
        self.index += 1
        while True:
            self.skip()
            if self.index >= len(self.text):
                raise SyntaxError("unterminated array")
            if self.text[self.index] == ")":
                self.index += 1
                return result
            result.append(self.parse_value())
            self.skip()
            if self.index < len(self.text) and self.text[self.index] == ",":
                self.index += 1

    def parse_quoted(self):
        self.index += 1
        out = []
        while self.index < len(self.text):
            character = self.text[self.index]
            if character == "\\":
                out.append(self.text[self.index + 1])
                self.index += 2
                continue
            if character == '"':
                self.index += 1
                return "".join(out)
            out.append(character)
            self.index += 1
        raise SyntaxError("unterminated string")

    def parse_bare(self):
        start = self.index
        while self.index < len(self.text) and self.text[self.index] not in ' \t\n\r;,=(){}"':
            self.index += 1
        if start == self.index:
            raise SyntaxError(f"unexpected character {self.text[self.index]!r} at line {self.line()}")
        return self.text[start:self.index]


def main() -> int:
    with open(PBXPROJ, encoding="utf-8") as handle:
        text = handle.read()

    try:
        plist = Parser(text).parse()
    except SyntaxError as error:
        print(f"pbxcheck: SYNTAX ERROR — {error}")
        return 1

    problems: list[str] = []
    objects = plist.get("objects", {})
    root_id = plist.get("rootObject")

    if root_id not in objects:
        problems.append("rootObject does not exist")

    # Every 24-hex token used as a value must name an object.
    def check_references(node, path: str):
        if isinstance(node, dict):
            for key, value in node.items():
                check_references(value, f"{path}.{key}")
        elif isinstance(node, list):
            for index, value in enumerate(node):
                check_references(value, f"{path}[{index}]")
        elif isinstance(node, str):
            if len(node) == 24 and all(c in "0123456789ABCDEF" for c in node):
                if node not in objects:
                    problems.append(f"{path} references unknown object {node}")

    for identifier, obj in objects.items():
        check_references(obj, f"{objects[identifier].get('isa', '?')}:{identifier}")

    project_dir = os.path.join(ROOT, "Apps")
    file_refs = {i: o for i, o in objects.items() if o.get("isa") == "PBXFileReference"}
    for identifier, ref in file_refs.items():
        if ref.get("sourceTree") == "BUILT_PRODUCTS_DIR":
            continue
        path = ref.get("path")
        if not path:
            problems.append(f"PBXFileReference {identifier} has no path")
            continue
        if not os.path.exists(os.path.join(project_dir, path)):
            problems.append(f"PBXFileReference {identifier} points at missing file {path}")

    grouped = set()
    for obj in objects.values():
        if obj.get("isa") == "PBXGroup":
            grouped.update(obj.get("children", []))
    for identifier in file_refs:
        if identifier not in grouped:
            problems.append(f"PBXFileReference {identifier} is not in any group")

    build_files = {i: o for i, o in objects.items() if o.get("isa") == "PBXBuildFile"}
    phased = set()
    for obj in objects.values():
        if obj.get("isa", "").endswith("BuildPhase"):
            phased.update(obj.get("files", []))
    for identifier in build_files:
        if identifier not in phased:
            problems.append(f"PBXBuildFile {identifier} is in no build phase")

    targets = {i: o for i, o in objects.items() if o.get("isa") == "PBXNativeTarget"}
    if not targets:
        problems.append("project has no targets")
    for identifier, target in targets.items():
        name = target.get("name", identifier)
        phases = [objects.get(p, {}).get("isa") for p in target.get("buildPhases", [])]
        if "PBXSourcesBuildPhase" not in phases:
            problems.append(f"target {name} has no sources phase")
        if target.get("buildConfigurationList") not in objects:
            problems.append(f"target {name} has no configuration list")
        source_phase = next(
            (objects[p] for p in target.get("buildPhases", [])
             if objects.get(p, {}).get("isa") == "PBXSourcesBuildPhase"),
            None,
        )
        if source_phase is not None and not source_phase.get("files"):
            problems.append(f"target {name} compiles no source files")

    lists = {i: o for i, o in objects.items() if o.get("isa") == "XCConfigurationList"}
    for identifier, config_list in lists.items():
        names = {objects.get(c, {}).get("name") for c in config_list.get("buildConfigurations", [])}
        if names != {"Debug", "Release"}:
            problems.append(f"XCConfigurationList {identifier} has configurations {sorted(names)}")

    for problem in problems:
        print(f"pbxcheck: {problem}")

    print(
        f"pbxcheck: {len(objects)} objects, {len(targets)} targets, "
        f"{len(file_refs)} file references, {len(problems)} problems"
    )
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
