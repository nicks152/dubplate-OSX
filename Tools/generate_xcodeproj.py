#!/usr/bin/env python3
"""Generates Apps/Dubplate.xcodeproj from the source tree.

The project is checked in so that `open Apps/Dubplate.xcodeproj` works with no
tooling installed, and generated so that adding a Swift file never means editing
a pbxproj by hand. Re-run after adding or removing application sources:

    python3 Tools/generate_xcodeproj.py

The shared modules are consumed as a local Swift package (the Package.swift at the
repository root), so this file only has to describe the two application targets and
the two UI test bundles.
"""

from __future__ import annotations

import hashlib
import os
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT_DIR = os.path.join(ROOT, "Apps", "Dubplate.xcodeproj")

MACOS_DEPLOYMENT = "15.0"
IOS_DEPLOYMENT = "18.0"
SWIFT_VERSION = "5.0"
BUNDLE_PREFIX = "com.dubplate.app"

PRODUCTS = ["DubplateCore", "DubplateAudio", "DubplateSync", "DubplateUI"]


def ident(*parts: str) -> str:
    """Stable 24-character hex identifier for an object."""
    digest = hashlib.sha1("::".join(parts).encode("utf-8")).hexdigest()
    return digest[:24].upper()


def swift_files(relative_dir: str) -> list[str]:
    base = os.path.join(ROOT, relative_dir)
    found = []
    for dirpath, _dirs, files in os.walk(base):
        for name in sorted(files):
            if name.endswith(".swift"):
                full = os.path.join(dirpath, name)
                found.append(os.path.relpath(full, os.path.join(ROOT, "Apps")))
    return sorted(found)


class Target:
    def __init__(self, name, product_type, sources_dir, platform, extra=None):
        self.name = name
        self.product_type = product_type
        self.sources_dir = sources_dir
        self.platform = platform
        self.extra = extra or {}
        self.sources = swift_files(sources_dir)
        self.id = ident("target", name)
        self.product_id = ident("product", name)
        self.sources_phase = ident("sources", name)
        self.frameworks_phase = ident("frameworks", name)
        self.resources_phase = ident("resources", name)
        self.config_list = ident("configlist", name)
        self.group = ident("group", name)


def build_targets() -> list[Target]:
    return [
        Target(
            "Dubplate Mac",
            "com.apple.product-type.application",
            "Apps/DubplateMac/Sources",
            "macos",
            {
                "INFOPLIST_FILE": "DubplateMac/Resources/Info.plist",
                "CODE_SIGN_ENTITLEMENTS": "DubplateMac/Resources/Dubplate.entitlements",
                "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_PREFIX,
                "PRODUCT_NAME": "Dubplate",
                "MACOSX_DEPLOYMENT_TARGET": MACOS_DEPLOYMENT,
                "SDKROOT": "macosx",
                "SUPPORTED_PLATFORMS": "macosx",
                "ENABLE_HARDENED_RUNTIME": "YES",
                "COMBINE_HIDPI_IMAGES": "YES",
            },
        ),
        Target(
            "Dubplate iOS",
            "com.apple.product-type.application",
            "Apps/DubplateiOS/Sources",
            "ios",
            {
                "INFOPLIST_FILE": "DubplateiOS/Resources/Info.plist",
                "CODE_SIGN_ENTITLEMENTS": "DubplateiOS/Resources/Dubplate.entitlements",
                "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_PREFIX,
                "PRODUCT_NAME": "Dubplate",
                "IPHONEOS_DEPLOYMENT_TARGET": IOS_DEPLOYMENT,
                "SDKROOT": "iphoneos",
                "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
                "TARGETED_DEVICE_FAMILY": "1,2",
                "SUPPORTS_MACCATALYST": "NO",
            },
        ),
        Target(
            "DubplateMacUITests",
            "com.apple.product-type.bundle.ui-testing",
            "Tests/UITests/Mac",
            "macos",
            {
                "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_PREFIX + ".macuitests",
                "PRODUCT_NAME": "DubplateMacUITests",
                "MACOSX_DEPLOYMENT_TARGET": MACOS_DEPLOYMENT,
                "SDKROOT": "macosx",
                "SUPPORTED_PLATFORMS": "macosx",
                "TEST_TARGET_NAME": "Dubplate Mac",
                "GENERATE_INFOPLIST_FILE": "YES",
            },
        ),
        Target(
            "DubplateiOSUITests",
            "com.apple.product-type.bundle.ui-testing",
            "Tests/UITests/Phone",
            "ios",
            {
                "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_PREFIX + ".iosuitests",
                "PRODUCT_NAME": "DubplateiOSUITests",
                "IPHONEOS_DEPLOYMENT_TARGET": IOS_DEPLOYMENT,
                "SDKROOT": "iphoneos",
                "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
                "TEST_TARGET_NAME": "Dubplate iOS",
                "GENERATE_INFOPLIST_FILE": "YES",
            },
        ),
    ]


SHARED_SETTINGS = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "COPY_PHASE_STRIP": "NO",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "SWIFT_VERSION": SWIFT_VERSION,
    "CODE_SIGN_STYLE": "Automatic",
    "DEVELOPMENT_TEAM": '""',
    "ENABLE_PREVIEWS": "YES",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
    "GENERATE_INFOPLIST_FILE": "NO",
    "CURRENT_PROJECT_VERSION": "1",
    "MARKETING_VERSION": "1.0",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "DEAD_CODE_STRIPPING": "YES",
}

DEBUG_SETTINGS = {
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
    "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"',
    "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
}

RELEASE_SETTINGS = {
    "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
    "ENABLE_NS_ASSERTIONS": "NO",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "SWIFT_OPTIMIZATION_LEVEL": '"-O"',
    "VALIDATE_PRODUCT": "YES",
}


def quote(value: str) -> str:
    if value == "":
        return '""'
    allowed = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./$()-")
    if all(character in allowed for character in value):
        return value
    if value.startswith('"') and value.endswith('"'):
        return value
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def settings_block(settings: dict[str, str], indent: str) -> str:
    lines = []
    for key in sorted(settings):
        lines.append(f"{indent}{key} = {quote(settings[key])};")
    return "\n".join(lines)


def generate() -> str:
    targets = build_targets()
    project_id = ident("project")
    main_group = ident("group", "main")
    products_group = ident("group", "products")
    package_ref = ident("package", "Dubplate")
    project_config_list = ident("configlist", "project")

    out: list[str] = []
    add = out.append

    add("// !$*UTF8*$!")
    add("{")
    add("\tarchiveVersion = 1;")
    add("\tclasses = {")
    add("\t};")
    add("\tobjectVersion = 56;")
    add("\tobjects = {")

    # ---- PBXBuildFile
    add("\n/* Begin PBXBuildFile section */")
    for target in targets:
        for path in target.sources:
            file_id = ident("file", path)
            build_id = ident("build", target.name, path)
            add(f"\t\t{build_id} /* {os.path.basename(path)} in Sources */ = "
                f"{{isa = PBXBuildFile; fileRef = {file_id} /* {os.path.basename(path)} */; }};")
        if target.product_type == "com.apple.product-type.application":
            for product in PRODUCTS:
                dep_id = ident("packageproduct", target.name, product)
                build_id = ident("packagebuild", target.name, product)
                add(f"\t\t{build_id} /* {product} in Frameworks */ = "
                    f"{{isa = PBXBuildFile; productRef = {dep_id} /* {product} */; }};")
    add("/* End PBXBuildFile section */")

    # ---- PBXFileReference
    add("\n/* Begin PBXFileReference section */")
    seen_files = set()
    for target in targets:
        for path in target.sources:
            if path in seen_files:
                continue
            seen_files.add(path)
            file_id = ident("file", path)
            add(f"\t\t{file_id} /* {os.path.basename(path)} */ = {{isa = PBXFileReference; "
                f"lastKnownFileType = sourcecode.swift; name = {quote(os.path.basename(path))}; "
                f"path = {quote(path)}; sourceTree = \"<group>\"; }};")
    for target in targets:
        extension = "app" if target.product_type.endswith("application") else "xctest"
        file_type = ("wrapper.application" if extension == "app"
                     else "wrapper.cfbundle")
        product_name = target.extra.get("PRODUCT_NAME", target.name)
        add(f"\t\t{target.product_id} /* {product_name}.{extension} */ = {{isa = PBXFileReference; "
            f"explicitFileType = {file_type}; includeInIndex = 0; "
            f"path = {quote(product_name + '.' + extension)}; sourceTree = BUILT_PRODUCTS_DIR; }};")
    for plist in ["DubplateMac/Resources/Info.plist", "DubplateMac/Resources/Dubplate.entitlements",
                  "DubplateiOS/Resources/Info.plist", "DubplateiOS/Resources/Dubplate.entitlements"]:
        file_id = ident("file", plist)
        kind = "text.plist.entitlements" if plist.endswith("entitlements") else "text.plist.xml"
        add(f"\t\t{file_id} /* {os.path.basename(plist)} */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = {kind}; name = {quote(os.path.basename(plist))}; "
            f"path = {quote(plist)}; sourceTree = \"<group>\"; }};")
    add("/* End PBXFileReference section */")

    # ---- PBXFrameworksBuildPhase
    add("\n/* Begin PBXFrameworksBuildPhase section */")
    for target in targets:
        add(f"\t\t{target.frameworks_phase} /* Frameworks */ = {{")
        add("\t\t\tisa = PBXFrameworksBuildPhase;")
        add("\t\t\tbuildActionMask = 2147483647;")
        add("\t\t\tfiles = (")
        if target.product_type == "com.apple.product-type.application":
            for product in PRODUCTS:
                build_id = ident("packagebuild", target.name, product)
                add(f"\t\t\t\t{build_id} /* {product} in Frameworks */,")
        add("\t\t\t);")
        add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
        add("\t\t};")
    add("/* End PBXFrameworksBuildPhase section */")

    # ---- PBXGroup
    add("\n/* Begin PBXGroup section */")
    add(f"\t\t{main_group} = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    for target in targets:
        add(f"\t\t\t\t{target.group} /* {target.name} */,")
    add(f"\t\t\t\t{products_group} /* Products */,")
    add("\t\t\t);")
    add("\t\t\tsourceTree = \"<group>\";")
    add("\t\t};")

    add(f"\t\t{products_group} /* Products */ = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    for target in targets:
        add(f"\t\t\t\t{target.product_id} /* {target.name} */,")
    add("\t\t\t);")
    add("\t\t\tname = Products;")
    add("\t\t\tsourceTree = \"<group>\";")
    add("\t\t};")

    for target in targets:
        add(f"\t\t{target.group} /* {target.name} */ = {{")
        add("\t\t\tisa = PBXGroup;")
        add("\t\t\tchildren = (")
        for path in target.sources:
            add(f"\t\t\t\t{ident('file', path)} /* {os.path.basename(path)} */,")
        if target.product_type == "com.apple.product-type.application":
            prefix = "DubplateMac" if target.platform == "macos" else "DubplateiOS"
            for name in ["Info.plist", "Dubplate.entitlements"]:
                path = f"{prefix}/Resources/{name}"
                add(f"\t\t\t\t{ident('file', path)} /* {name} */,")
        add("\t\t\t);")
        add(f"\t\t\tname = {quote(target.name)};")
        add("\t\t\tsourceTree = \"<group>\";")
        add("\t\t};")
    add("/* End PBXGroup section */")

    # ---- PBXNativeTarget
    add("\n/* Begin PBXNativeTarget section */")
    for target in targets:
        add(f"\t\t{target.id} /* {target.name} */ = {{")
        add("\t\t\tisa = PBXNativeTarget;")
        add(f"\t\t\tbuildConfigurationList = {target.config_list} /* Build configuration list */;")
        add("\t\t\tbuildPhases = (")
        add(f"\t\t\t\t{target.sources_phase} /* Sources */,")
        add(f"\t\t\t\t{target.frameworks_phase} /* Frameworks */,")
        add(f"\t\t\t\t{target.resources_phase} /* Resources */,")
        add("\t\t\t);")
        add("\t\t\tbuildRules = (")
        add("\t\t\t);")
        add("\t\t\tdependencies = (")
        if target.product_type.endswith("ui-testing"):
            host = "Dubplate Mac" if target.platform == "macos" else "Dubplate iOS"
            add(f"\t\t\t\t{ident('targetdep', target.name)} /* PBXTargetDependency */,")
        add("\t\t\t);")
        add(f"\t\t\tname = {quote(target.name)};")
        if target.product_type == "com.apple.product-type.application":
            add("\t\t\tpackageProductDependencies = (")
            for product in PRODUCTS:
                add(f"\t\t\t\t{ident('packageproduct', target.name, product)} /* {product} */,")
            add("\t\t\t);")
        add(f"\t\t\tproductName = {quote(target.extra.get('PRODUCT_NAME', target.name))};")
        add(f"\t\t\tproductReference = {target.product_id} /* product */;")
        add(f"\t\t\tproductType = \"{target.product_type}\";")
        add("\t\t};")
    add("/* End PBXNativeTarget section */")

    # ---- PBXProject
    add("\n/* Begin PBXProject section */")
    add(f"\t\t{project_id} /* Project object */ = {{")
    add("\t\t\tisa = PBXProject;")
    add("\t\t\tattributes = {")
    add("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    add("\t\t\t\tLastSwiftUpdateCheck = 1600;")
    add("\t\t\t\tLastUpgradeCheck = 1600;")
    add("\t\t\t\tTargetAttributes = {")
    for target in targets:
        add(f"\t\t\t\t\t{target.id} = {{")
        add("\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;")
        if target.product_type.endswith("ui-testing"):
            host = "Dubplate Mac" if target.platform == "macos" else "Dubplate iOS"
            add(f"\t\t\t\t\t\tTestTargetID = {ident('target', host)};")
        add("\t\t\t\t\t};")
    add("\t\t\t\t};")
    add("\t\t\t};")
    add(f"\t\t\tbuildConfigurationList = {project_config_list} /* Build configuration list */;")
    add("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    add("\t\t\tdevelopmentRegion = en;")
    add("\t\t\thasScannedForEncodings = 0;")
    add("\t\t\tknownRegions = (")
    add("\t\t\t\ten,")
    add("\t\t\t\tBase,")
    add("\t\t\t);")
    add(f"\t\t\tmainGroup = {main_group};")
    add("\t\t\tpackageReferences = (")
    add(f"\t\t\t\t{package_ref} /* XCLocalSwiftPackageReference \"..\" */,")
    add("\t\t\t);")
    add(f"\t\t\tproductRefGroup = {products_group} /* Products */;")
    add("\t\t\tprojectDirPath = \"\";")
    add("\t\t\tprojectRoot = \"\";")
    add("\t\t\ttargets = (")
    for target in targets:
        add(f"\t\t\t\t{target.id} /* {target.name} */,")
    add("\t\t\t);")
    add("\t\t};")
    add("/* End PBXProject section */")

    # ---- PBXResourcesBuildPhase
    add("\n/* Begin PBXResourcesBuildPhase section */")
    for target in targets:
        add(f"\t\t{target.resources_phase} /* Resources */ = {{")
        add("\t\t\tisa = PBXResourcesBuildPhase;")
        add("\t\t\tbuildActionMask = 2147483647;")
        add("\t\t\tfiles = (")
        add("\t\t\t);")
        add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
        add("\t\t};")
    add("/* End PBXResourcesBuildPhase section */")

    # ---- PBXSourcesBuildPhase
    add("\n/* Begin PBXSourcesBuildPhase section */")
    for target in targets:
        add(f"\t\t{target.sources_phase} /* Sources */ = {{")
        add("\t\t\tisa = PBXSourcesBuildPhase;")
        add("\t\t\tbuildActionMask = 2147483647;")
        add("\t\t\tfiles = (")
        for path in target.sources:
            build_id = ident("build", target.name, path)
            add(f"\t\t\t\t{build_id} /* {os.path.basename(path)} in Sources */,")
        add("\t\t\t);")
        add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
        add("\t\t};")
    add("/* End PBXSourcesBuildPhase section */")

    # ---- PBXTargetDependency
    add("\n/* Begin PBXTargetDependency section */")
    for target in targets:
        if not target.product_type.endswith("ui-testing"):
            continue
        host = "Dubplate Mac" if target.platform == "macos" else "Dubplate iOS"
        proxy = ident("containerproxy", target.name)
        add(f"\t\t{ident('targetdep', target.name)} /* PBXTargetDependency */ = {{")
        add("\t\t\tisa = PBXTargetDependency;")
        add(f"\t\t\ttarget = {ident('target', host)} /* {host} */;")
        add(f"\t\t\ttargetProxy = {proxy} /* PBXContainerItemProxy */;")
        add("\t\t};")
    add("/* End PBXTargetDependency section */")

    add("\n/* Begin PBXContainerItemProxy section */")
    for target in targets:
        if not target.product_type.endswith("ui-testing"):
            continue
        host = "Dubplate Mac" if target.platform == "macos" else "Dubplate iOS"
        add(f"\t\t{ident('containerproxy', target.name)} /* PBXContainerItemProxy */ = {{")
        add("\t\t\tisa = PBXContainerItemProxy;")
        add(f"\t\t\tcontainerPortal = {project_id} /* Project object */;")
        add("\t\t\tproxyType = 1;")
        add(f"\t\t\tremoteGlobalIDString = {ident('target', host)};")
        add(f"\t\t\tremoteInfo = {quote(host)};")
        add("\t\t};")
    add("/* End PBXContainerItemProxy section */")

    # ---- XCBuildConfiguration
    add("\n/* Begin XCBuildConfiguration section */")
    for name, extra in [("Debug", DEBUG_SETTINGS), ("Release", RELEASE_SETTINGS)]:
        config_id = ident("config", "project", name)
        add(f"\t\t{config_id} /* {name} */ = {{")
        add("\t\t\tisa = XCBuildConfiguration;")
        add("\t\t\tbuildSettings = {")
        merged = dict(SHARED_SETTINGS)
        merged.update(extra)
        add(settings_block(merged, "\t\t\t\t"))
        add("\t\t\t};")
        add(f"\t\t\tname = {name};")
        add("\t\t};")
    for target in targets:
        for name in ["Debug", "Release"]:
            config_id = ident("config", target.name, name)
            add(f"\t\t{config_id} /* {name} */ = {{")
            add("\t\t\tisa = XCBuildConfiguration;")
            add("\t\t\tbuildSettings = {")
            add(settings_block(target.extra, "\t\t\t\t"))
            add("\t\t\t};")
            add(f"\t\t\tname = {name};")
            add("\t\t};")
    add("/* End XCBuildConfiguration section */")

    # ---- XCConfigurationList
    add("\n/* Begin XCConfigurationList section */")
    for owner, list_id in [("project", project_config_list)] + [(t.name, t.config_list) for t in targets]:
        add(f"\t\t{list_id} /* Build configuration list for {owner} */ = {{")
        add("\t\t\tisa = XCConfigurationList;")
        add("\t\t\tbuildConfigurations = (")
        for name in ["Debug", "Release"]:
            add(f"\t\t\t\t{ident('config', owner, name)} /* {name} */,")
        add("\t\t\t);")
        add("\t\t\tdefaultConfigurationIsVisible = 0;")
        add("\t\t\tdefaultConfigurationName = Release;")
        add("\t\t};")
    add("/* End XCConfigurationList section */")

    # ---- Swift package
    add("\n/* Begin XCLocalSwiftPackageReference section */")
    add(f"\t\t{package_ref} /* XCLocalSwiftPackageReference \"..\" */ = {{")
    add("\t\t\tisa = XCLocalSwiftPackageReference;")
    add("\t\t\trelativePath = ..;")
    add("\t\t};")
    add("/* End XCLocalSwiftPackageReference section */")

    add("\n/* Begin XCSwiftPackageProductDependency section */")
    for target in targets:
        if target.product_type != "com.apple.product-type.application":
            continue
        for product in PRODUCTS:
            add(f"\t\t{ident('packageproduct', target.name, product)} /* {product} */ = {{")
            add("\t\t\tisa = XCSwiftPackageProductDependency;")
            add(f"\t\t\tproductName = {product};")
            add("\t\t};")
    add("/* End XCSwiftPackageProductDependency section */")

    add("\t};")
    add(f"\trootObject = {project_id} /* Project object */;")
    add("}")
    return "\n".join(out) + "\n"


SCHEME_TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target_id}"
               BuildableName = "{product_name}.app"
               BlueprintName = "{target_name}"
               ReferencedContainer = "container:Dubplate.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
{testables}      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}"
            BuildableName = "{product_name}.app"
            BlueprintName = "{target_name}"
            ReferencedContainer = "container:Dubplate.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}"
            BuildableName = "{product_name}.app"
            BlueprintName = "{target_name}"
            ReferencedContainer = "container:Dubplate.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""

TESTABLE_TEMPLATE = """         <TestableReference skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{blueprint}"
               BuildableName = "{buildable}"
               BlueprintName = "{name}"
               ReferencedContainer = "container:{container}">
            </BuildableReference>
         </TestableReference>
"""


def write_schemes(targets):
    scheme_dir = os.path.join(PROJECT_DIR, "xcshareddata", "xcschemes")
    os.makedirs(scheme_dir, exist_ok=True)
    package_tests = ["CoreTests", "AudioTests", "SyncTests"]

    for app, ui_tests in [("Dubplate Mac", "DubplateMacUITests"), ("Dubplate iOS", "DubplateiOSUITests")]:
        testables = ""
        for name in package_tests:
            testables += TESTABLE_TEMPLATE.format(
                blueprint=name, buildable=name, name=name, container="../Dubplate"
            )
        testables += TESTABLE_TEMPLATE.format(
            blueprint=ident("target", ui_tests),
            buildable=f"{ui_tests}.xctest",
            name=ui_tests,
            container="Dubplate.xcodeproj",
        )
        scheme = SCHEME_TEMPLATE.format(
            target_id=ident("target", app),
            target_name=app,
            product_name="Dubplate",
            testables=testables,
        )
        with open(os.path.join(scheme_dir, f"{app}.xcscheme"), "w", encoding="utf-8") as handle:
            handle.write(scheme)


def main() -> int:
    targets = build_targets()
    missing = [t.name for t in targets if not t.sources]
    if missing:
        print(f"warning: no Swift sources found for {', '.join(missing)}", file=sys.stderr)

    os.makedirs(PROJECT_DIR, exist_ok=True)
    with open(os.path.join(PROJECT_DIR, "project.pbxproj"), "w", encoding="utf-8") as handle:
        handle.write(generate())
    write_schemes(targets)

    workspace_dir = os.path.join(PROJECT_DIR, "project.xcworkspace")
    os.makedirs(workspace_dir, exist_ok=True)
    with open(os.path.join(workspace_dir, "contents.xcworkspacedata"), "w", encoding="utf-8") as handle:
        handle.write(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<Workspace version = "1.0">\n'
            '   <FileRef location = "self:">\n'
            '   </FileRef>\n'
            '</Workspace>\n'
        )

    total = sum(len(t.sources) for t in targets)
    print(f"generated {os.path.relpath(PROJECT_DIR, ROOT)} with {len(targets)} targets, {total} source files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
