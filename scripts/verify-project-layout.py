#!/usr/bin/env python3
"""Check that CivitViewer's on-disk sources and resources match the Xcode target."""
from collections import Counter
import json
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = ROOT / "CivitViewer"
PROJECT = ROOT / "CivitViewer.xcodeproj" / "project.pbxproj"


def verify():
    result = subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(PROJECT)])
    project = json.loads(result)
    objects = project["objects"]
    main_group = objects[objects[project["rootObject"]]["mainGroup"]]
    source_group, = (key for key in main_group["children"]
                     if objects[key].get("path") == SOURCE_ROOT.name)
    references = {}

    def read_group(key, parent):
        group = objects[key]
        directory = parent / group["path"]
        if not directory.is_dir():
            raise SystemExit(f"Xcode group points to missing directory {directory.relative_to(ROOT)}")
        for child in group["children"]:
            node = objects[child]
            if node["isa"] == "PBXGroup":
                read_group(child, directory)
            elif node["isa"] == "PBXFileReference" and node["sourceTree"] == "<group>":
                path = directory / node["path"]
                if child in references or not path.exists():
                    raise SystemExit(f"Duplicate or missing Xcode reference {path.relative_to(ROOT)}")
                references[child] = path.relative_to(ROOT)

    read_group(source_group, ROOT)
    target, = (obj for obj in objects.values()
               if obj["isa"] == "PBXNativeTarget" and obj["name"] == "CivitViewer")

    def target_paths(phase_type):
        phase, = (objects[key] for key in target["buildPhases"]
                  if objects[key]["isa"] == phase_type)
        return Counter(references[objects[key]["fileRef"]] for key in phase["files"])

    def compare(label, actual, expected):
        if actual != expected:
            missing = ", ".join(map(str, sorted((expected - actual).elements())))
            extra = ", ".join(map(str, sorted((actual - expected).elements())))
            raise SystemExit(f"{label} mismatch\nMissing: {missing or 'none'}\nExtra or duplicate: {extra or 'none'}")

    sources = Counter(path.relative_to(ROOT) for path in SOURCE_ROOT.rglob("*.swift"))
    resources = Counter(Path("CivitViewer/Resources") / name
                        for name in ("Assets.xcassets", "FFmpeg-LGPL.txt"))
    compare("Project navigator", Counter(references.values()),
            sources + resources + Counter([Path("CivitViewer/Info.plist")]))
    compare("App target sources", target_paths("PBXSourcesBuildPhase"), sources)
    compare("App target resources", target_paths("PBXResourcesBuildPhase"), resources)
    print(f"Project layout verified: {len(sources)} Swift files, {len(resources)} bundled resource entries")


if __name__ == "__main__":
    verify()
