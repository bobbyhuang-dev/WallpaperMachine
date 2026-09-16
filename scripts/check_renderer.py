#!/usr/bin/env python3
"""Non-desktop renderer regressions: generated scenes and optional local projects.

Creates only private GPU images. Never launches the app, captures the screen,
initializes sound, changes wallpapers, or controls Spaces. Local packages stay put.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import subprocess

from build import build_environment
from lib.paths import RENDERER, RENDERER_ARTIFACTS, ROOT

GENERATED_CASE_COUNT = 9


def run(command, log, env, timeout=180):
    with log.open("w") as stream:
        return subprocess.run(list(map(str, command)), cwd=ROOT, env=env,
                              stdout=stream, stderr=subprocess.STDOUT,
                              timeout=timeout, check=False).returncode


def fixtures(root):
    """Original synthetic assets, no workshop identifiers or copyrighted content."""
    for index in range(8):
        folder = root / f"generated-{index}"
        folder.mkdir(parents=True, exist_ok=True)
        files = {
            "project.json": json.dumps({"title": f"Generated {index}", "type": "scene", "file": "layout.json", "general": {"properties": {}}}),
            "models/tile.json": json.dumps({"width": 64, "height": 48, "material": "materials/tile.json"}),
            "materials/tile.json": json.dumps({"passes": [{"shader": "probe_tile", "blending": "translucent", "cullmode": "nocull", "depthtest": "disabled", "depthwrite": "disabled"}]}),
            "effects/probe.json": json.dumps({"name": "probe copy", "passes": [{"material": "materials/copy.json"}]}),
            "materials/copy.json": json.dumps({"passes": [{"shader": "probe_copy", "blending": "translucent", "cullmode": "nocull", "depthtest": "disabled", "depthwrite": "disabled", "textures": [None]}]}),
            "shaders/probe_tile.vert": "uniform mat4 g_ModelViewProjectionMatrix; attribute vec3 a_Position; attribute vec2 a_TexCoord; varying vec2 v_TexCoord; void main(){gl_Position=g_ModelViewProjectionMatrix*vec4(a_Position,1.0);v_TexCoord=a_TexCoord;}",
            "shaders/probe_tile.frag": "varying vec2 v_TexCoord; void main(){gl_FragColor=vec4(v_TexCoord,0.3,0.8);}",
            "shaders/probe_copy.frag": "uniform sampler2D g_Texture0; varying vec2 v_TexCoord; void main(){gl_FragColor=texture(g_Texture0,v_TexCoord);}",
        }
        files["shaders/probe_copy.vert"] = files["shaders/probe_tile.vert"]
        def tile(id_, name, origin, parent=None):
            obj = {"id": id_, "name": name, "image": "models/tile.json", "origin": origin, "scale": [1,1,1], "angles": [0,0,0], "visible": True}
            if parent is not None:
                obj["parent"] = parent
            return obj
        # Reusable poison target, empty effect, and nested compose children.
        poison = tile(100, "first effect", [40,40,0])
        poison["effects"] = [{"file": "effects/probe.json", "visible": True}]
        compose = {"id": 200, "name": "container", "image": "models/util/composelayer.json", "size": [96 + index * 3,72 + index * 2], "origin": [180,120,0], "scale": [-1 if index % 2 else 1,0.8,1], "angles": [0,0,0.1 * index], "copybackground": bool(index % 2), "effects": [{"file": "effects/probe.json", "visible": True}], "visible": index != 6}
        objects = [poison, compose]
        if index >= 2:
            objects.append(tile(201, "child", [0,0,0], 200))
        if index >= 4:
            inner = dict(compose, id=300, name="inner", parent=200, origin=[15,0,0], size=[64,48], copybackground=False)
            objects.extend([inner, tile(301, "grandchild", [0,0,0], 300)])
        if index == 7:
            objects.reverse()  # Declaration order/ID is not a resource identity.
        scene = {"camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
                 "general": {"ambientcolor":[0,0,0], "skylightcolor":[0,0,0], "clearcolor":[0.02,0.05,0.08], "cameraparallax":False, "orthogonalprojection":{"width":384,"height":256}}, "objects": objects}
        files["layout.json"] = json.dumps(scene)
        for name, contents in files.items():
            path = folder / name
            path.parent.mkdir(parents=True, exist_ok=True)
            if name.startswith("shaders/"):
                contents = contents.replace(";", ";\n").replace("{", "{\n").replace("}", "\n}\n")
            path.write_text(contents)
        yield folder / "project.json"


def alpha_composite_fixture(root):
    """Expose composed coverage as RGB, independent of source artwork or effects."""
    folder = root / "generated-alpha"
    vertex = """uniform mat4 g_ModelViewProjectionMatrix;
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
    gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);
    v_TexCoord = a_TexCoord;
}
"""
    fragments = {
        "under": """varying vec2 v_TexCoord;
void main() {
    gl_FragColor = vec4(0.2, 0.4, 0.6, floor(v_TexCoord.x * 3.0) * 0.5);
}
""",
        "over": """void main() {
    gl_FragColor = vec4(0.8, 0.6, 0.4, 0.5);
}
""",
        "coverage": """uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
    float coverage = texture(g_Texture0, v_TexCoord).a;
    gl_FragColor = vec4(vec3(coverage), 1.0);
}
""",
    }
    files = {
        "project.json": {"title": "Source-over coverage", "type": "scene", "file": "layout.json", "general": {"properties": {}}},
        "effects/coverage.json": {"name": "coverage readback", "passes": [{"material": "materials/coverage.json"}]},
    }
    for name, fragment in fragments.items():
        files[f"materials/{name}.json"] = {"passes": [{"shader": name, "blending": "translucent", "cullmode": "nocull", "depthtest": "disabled", "depthwrite": "disabled", "textures": [None]}]}
        files[f"models/{name}.json"] = {"width": 288, "height": 144, "material": f"materials/{name}.json"}
        files[f"shaders/{name}.vert"] = vertex
        files[f"shaders/{name}.frag"] = fragment
    files["layout.json"] = {
        "camera": {"center": [0, 0, 0], "eye": [0, 0, 1], "up": [0, 1, 0]},
        "general": {"clearcolor": [0.1, 0.2, 0.3], "cameraparallax": False, "orthogonalprojection": {"width": 384, "height": 256}},
        "objects": [
            {"id": 1, "name": "coverage container", "image": "models/util/composelayer.json", "size": [288, 144], "origin": [192, 128, 0], "copybackground": False, "effects": [{"file": "effects/coverage.json", "visible": True}]},
            {"id": 2, "name": "destination", "parent": 1, "image": "models/under.json", "origin": [0, 0, 0]},
            {"id": 3, "name": "source", "parent": 1, "image": "models/over.json", "origin": [0, 0, 0]},
        ],
    }
    for name, contents in files.items():
        path = folder / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents if isinstance(contents, str) else json.dumps(contents))
    return folder / "project.json"


def check_generated_pixels(data, index):
    """Independent assertions so two equally blank/corrupt outputs cannot pass."""
    magic, dimensions, maximum, pixels = data.split(b"\n", 3)
    width, height = map(int, dimensions.split())
    if (magic, maximum, width, height) != (b"P6", b"255", 384, 256):
        return False
    if len(pixels) != width * height * 3:
        return False
    def pixel(x, y):
        offset = (y * width + x) * 3
        return pixels[offset:offset + 3]
    if index == 8:
        # A half-covered source over transparent, half-covered and opaque targets:
        # Aout = As + Ad * (1 - As). RGB readback makes lost coverage observable.
        return all(abs(channel - expected) <= 1
                   for x, expected in [(96, 128), (192, 191), (288, 255)]
                   for channel in pixel(x, 128))
    background = pixel(0, 0)
    # First effect must really draw; empty/hidden nested layers must not leak
    # that earlier effect's pixels. Visible children must survive their clears.
    if pixel(40, 216) == background:
        return False
    if index in (0, 1, 6):
        return all(pixel(x, y) == background for y in range(130, 142) for x in range(174, 186))
    return pixel(180, 136) != background


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assets", type=Path, default=Path.home() / "Library/Application Support/mac-wallpaper-engine/SceneAssets")
    parser.add_argument("--project", action="append", type=Path, default=[], help="Additional local scene project; repeatable")
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()
    out = RENDERER_ARTIFACTS / ("adaptive-" + datetime.now().strftime("%Y%m%d-%H%M%S"))
    out.mkdir(parents=True)
    env = build_environment()
    build = RENDERER_ARTIFACTS / "bin"
    if not args.skip_build:
        steps = [
            (["cargo", "build", "--manifest-path", RENDERER / "Cargo.toml", "-p", "shader", "--features", "ffi", "--release"], "shader-build"),
            (["cmake", "-S", RENDERER / "external/open-wallpaper-engine", "-B", build, "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_TESTS=ON", "-DBUILD_QML=OFF", "-DBUILD_WAYWALLEN=OFF", "-DRUST_SHADER_FFI=ON", "-DRUST_SHADER_STATICLIB=" + str(RENDERER / "target/release/libshader.a")], "configure"),
            (["cmake", "--build", build, "--target", "offscreen_scene_probe", "scene_reload_cycle_probe", "render_target_lifetime_test", "text_object_runtime_test", "shader_cache_metadata_test", "-j", "6"], "build"),
        ]
        for command, name in steps:
            if run(command, out / (name + ".log"), env, 600):
                print(f"Build failed; see {out / (name + '.log')}")
                return 1
    report = {"desktop_automation": False, "gpu_surface": False, "cases": []}
    for binary in ["render_target_lifetime_test", "text_object_runtime_test", "shader_cache_metadata_test"]:
        status = run([build / "tests" / binary], out / (binary + ".log"), env)
        report[ binary ] = status
    for project in [*fixtures(out / "fixtures"), alpha_composite_fixture(out / "fixtures"), *args.project]:
        project = project.resolve()
        manifest_bytes = project.read_bytes()
        manifest = json.loads(manifest_bytes)
        package = project.parent / Path(manifest.get("file", "scene.json")).with_suffix(".pkg")
        case = {"project": str(project), "runs": [], "project_sha256": hashlib.sha256(manifest_bytes).hexdigest()}
        if package.is_file():
            with package.open("rb") as stream:
                case["package_sha256"] = hashlib.file_digest(stream, "sha256").hexdigest()
        case_dir = out / ("case-" + str(len(report["cases"])))
        case_dir.mkdir()
        for mode in ["pooled", "isolated"]:
            mode_env = env.copy()
            mode_env.update(WE_TEST_PROJECT=str(project), WE_TEST_ASSETS=str(args.assets.resolve()), WE_TEST_OUTPUT=str(case_dir / mode))
            for key in ["WE_TEST_NO_REUSE", "WE_TEST_DUMP_PASSES", "WE_DEBUG_SKIP_NODE", "WE_DEBUG_SKIP_MATERIAL", "WE_DEBUG_SKIP_PASSTHROUGH"]:
                mode_env.pop(key, None)
            if mode == "isolated":
                mode_env["WE_TEST_NO_REUSE"] = "1"
            try:
                status = run([build / "tests/offscreen_scene_probe"], case_dir / (mode + ".log"), mode_env)
            except subprocess.TimeoutExpired:
                status = "timeout"
            case["runs"].append({"mode": mode, "exit": status})
        # Rendering without a crash does not prove all authored effects loaded.
        case["diagnostics"] = []
        for mode in ["pooled", "isolated"]:
            for line in (case_dir / (mode + ".log")).read_text(errors="replace").splitlines():
                if "ERROR" in line and 'not found "/cache/' not in line:
                    if line not in case["diagnostics"]:
                        case["diagnostics"].append(line)
        case["pixels_equal"] = False
        if all(r["exit"] == 0 for r in case["runs"]):
            pooled = (case_dir / "pooled/frame-2.ppm").read_bytes()
            isolated = (case_dir / "isolated/frame-2.ppm").read_bytes()
            case["pixels_equal"] = pooled == isolated
            case["sha256"] = hashlib.sha256(pooled).hexdigest()
            if len(report["cases"]) < GENERATED_CASE_COUNT:
                case["expected_pixels"] = check_generated_pixels(pooled, len(report["cases"]))
        case["full_compatibility_verified"] = False  # No authored-reference comparison.
        report["cases"].append(case)
        (out / "report.json").write_text(json.dumps(report, indent=2))
        print(f"{project.parent.name}: {case['runs']}; pixels_equal={case['pixels_equal']}; diagnostics={len(case['diagnostics'])}", flush=True)
    # Switching wallpapers reloads scenes inside one process; per-process state
    # left behind by a previous load must not stall the next parse.
    reload_projects = [p.resolve() for p in args.project] or list(fixtures(out / "fixtures"))
    reload_env = env.copy()
    reload_env.update(
        WE_TEST_PROJECTS=";".join(str(p) for p in reload_projects),
        WE_TEST_ASSETS=str(args.assets.resolve()),
        WE_TEST_OUTPUT=str(out / "reload-cycles"),
        WE_TEST_CYCLES="2",
    )
    try:
        report["scene_reload_cycle_probe"] = run(
            [build / "tests/scene_reload_cycle_probe"], out / "reload-cycles.log", reload_env,
            60 + 60 * len(reload_projects))
    except subprocess.TimeoutExpired:
        report["scene_reload_cycle_probe"] = "timeout"
    (out / "report.json").write_text(json.dumps(report, indent=2))
    print(f"reload cycles ({len(reload_projects)} projects x2): {report['scene_reload_cycle_probe']}", flush=True)
    print(f"Evidence: {out}")
    return int(any(report[k] for k in ["render_target_lifetime_test", "text_object_runtime_test", "shader_cache_metadata_test", "scene_reload_cycle_probe"]) or any(not c["pixels_equal"] for c in report["cases"]) or any(c["diagnostics"] or not c.get("expected_pixels", False) for c in report["cases"][:GENERATED_CASE_COUNT]))


if __name__ == "__main__":
    raise SystemExit(main())
