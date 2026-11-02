"""Create a minimal normal Xcode signing project for the compiled probe."""

import argparse
import os
from pathlib import Path
import plistlib

os.umask(0o077)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--build-dir", type=Path, required=True)
args = parser.parse_args()
task = args.output.resolve()
task.mkdir(parents=True, mode=0o700, exist_ok=True)
root = task / "provisioning-probe"
project = root / "SofaRenewalProbe.xcodeproj"
assert not (project / "project.pbxproj").exists(), "Preserve the prepared project"
project.mkdir(parents=True, mode=0o700, exist_ok=True)
bundle_id = "com.joeyteng.sofaremote.renewalprobe.mac"
identifiers = {name: f"{index:024X}" for index, name in enumerate((
    "project", "rootGroup", "products", "product", "target", "copy", "projectConfigs", "targetConfigs",
    "projectDebug", "projectRelease", "targetDebug", "targetRelease"), 1)}
objects = {}


def put(label, **value):
    objects[identifiers[label]] = value


put("project", isa="PBXProject", attributes={"LastUpgradeCheck": "2600", "TargetAttributes": {
    identifiers["target"]: {"CreatedOnToolsVersion": "26.6", "ProvisioningStyle": "Automatic",
        "SystemCapabilities": {"com.apple.Keychain": {"enabled": 1}}}}},
    buildConfigurationList=identifiers["projectConfigs"], compatibilityVersion="Xcode 14.0",
    developmentRegion="en", hasScannedForEncodings=0, knownRegions=["en", "Base"],
    mainGroup=identifiers["rootGroup"], productRefGroup=identifiers["products"],
    projectDirPath="", projectRoot="", targets=[identifiers["target"]])
put("rootGroup", isa="PBXGroup", children=[identifiers["products"]], sourceTree="<group>")
put("products", isa="PBXGroup", children=[identifiers["product"]], name="Products", sourceTree="<group>")
put("product", isa="PBXFileReference", explicitFileType="wrapper.application", includeInIndex=0,
    path="SofaRenewalProbe.app", sourceTree="BUILT_PRODUCTS_DIR")
put("target", isa="PBXNativeTarget", buildConfigurationList=identifiers["targetConfigs"],
    buildPhases=[identifiers["copy"]], buildRules=[], dependencies=[], name="SofaRenewalProbe",
    productName="SofaRenewalProbe", productReference=identifiers["product"], productType="com.apple.product-type.application")
put("copy", isa="PBXShellScriptBuildPhase", buildActionMask=2147483647, files=[],
    inputPaths=["$(SOFA_PROBE_INPUT_BINARY)"], name="Copy independently built probe",
    outputPaths=["$(TARGET_BUILD_DIR)/$(EXECUTABLE_FOLDER_PATH)/$(EXECUTABLE_NAME)"],
    runOnlyForDeploymentPostprocessing=0, shellPath="/bin/sh",
    shellScript='set -eu\nmkdir -p "$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH"\n'
        'cp "$SOFA_PROBE_INPUT_BINARY" "$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/$EXECUTABLE_NAME"\n'
        'chmod 700 "$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/$EXECUTABLE_NAME"\n')
for name, configs in (("projectConfigs", ["projectDebug", "projectRelease"]), ("targetConfigs", ["targetDebug", "targetRelease"])):
    put(name, isa="XCConfigurationList", buildConfigurations=[identifiers[key] for key in configs],
        defaultConfigurationIsVisible=0, defaultConfigurationName="Debug")
for configuration in ("Debug", "Release"):
    put(f"project{configuration}", isa="XCBuildConfiguration", name=configuration,
        buildSettings={"SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "14.0"})
    put(f"target{configuration}", isa="XCBuildConfiguration", name=configuration, buildSettings={
        "PRODUCT_NAME": "SofaRenewalProbe", "PRODUCT_BUNDLE_IDENTIFIER": bundle_id,
        "SUPPORTED_PLATFORMS": "macosx", "MACOSX_DEPLOYMENT_TARGET": "14.0", "SDKROOT": "macosx",
        "CODE_SIGN_STYLE": "Automatic", "CODE_SIGN_ENTITLEMENTS": "Probe.entitlements",
        "INFOPLIST_FILE": "Info.plist", "GENERATE_INFOPLIST_FILE": "NO",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO", "ENABLE_HARDENED_RUNTIME": "NO",
        "SOFA_PROBE_INPUT_BINARY": str((args.build_dir / "debug/xtool").resolve()),
    })
(project / "project.pbxproj").write_bytes(plistlib.dumps({"archiveVersion": "1", "classes": {},
    "objectVersion": "56", "objects": objects, "rootObject": identifiers["project"]}))
(root / "Probe.entitlements").write_bytes(plistlib.dumps({
    "keychain-access-groups": [f"$(AppIdentifierPrefix){bundle_id}"]}))
(root / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
    "CFBundleExecutable": "$(EXECUTABLE_NAME)", "CFBundleName": "Sofa Renewal Probe", "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "0.1", "CFBundleVersion": "1", "LSUIElement": True,
    "LSMinimumSystemVersion": "14.0"}))
schemes = project / "xcshareddata/xcschemes"
schemes.mkdir(parents=True, mode=0o700)
(schemes / "SofaRenewalProbe.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="NO" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
      <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{identifiers['target']}" BuildableName="SofaRenewalProbe.app" BlueprintName="SofaRenewalProbe" ReferencedContainer="container:SofaRenewalProbe.xcodeproj"/>
    </BuildActionEntry>
  </BuildActionEntries></BuildAction>
</Scheme>
''')
print("Prepared a standalone Xcode signing project; no account operation performed.")
