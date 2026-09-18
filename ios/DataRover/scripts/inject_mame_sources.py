#!/usr/bin/env python3
"""Inject MAME file-list sources into the xcodegen-generated pbxproj.

xcodegen has no file-list include mechanism, so the DataRoverCore target's
MAME sources (Core/file-list.txt, MAME_DIR-relative) are added here as
explicit PBXBuildFile/PBXFileReference entries with $(MAME_DIR) paths.
Idempotent: skips sources already present. Run after `xcodegen generate`.

Per-file COMPILER_FLAGS carry each owning GENie lib's local defines/includes
(mirroring build/projects/sdl3/mamedatarover/gmake-osx-clang/*.make) so the
global target settings stay shadowing-safe:
- HAVE_CONFIG_H + FLAC include dirs live ONLY on flac/ entries (a global
  <config.h> would resolve to src/emu/config.h for every other C TU).
- asmjit/ entries get -include $(SRCROOT)/Core/datarover_asmjit_ios.h
  (upstream gates sys_icache_invalidate's header on TARGET_OS_OSX).
- ocore/osd entries drop the SDL OSD defines (headless: no SDL on iOS).

Usage: python3 scripts/inject_mame_sources.py [--project DIR]
"""
import argparse
import hashlib
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_PROJ = os.path.normpath(os.path.join(HERE, "..", "DataRover.xcodeproj"))
LIBMAP = "/tmp/ios_libmap.json"


def uuid_for(key):
    return hashlib.sha1(("datarover:" + key).encode()).hexdigest()[:24].upper()


def load_file_list():
    path = os.path.normpath(os.path.join(HERE, "..", "Core", "file-list.txt"))
    with open(path) as f:
        return [ln.strip() for ln in f if ln.strip()]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", default=DEFAULT_PROJ)
    args = ap.parse_args()
    pbxproj = os.path.join(args.project, "project.pbxproj")
    if not os.path.exists(pbxproj):
        print(f"no project at {pbxproj}; run xcodegen generate first", file=sys.stderr)
        return 2
    srcs = load_file_list()
    with open(pbxproj) as f:
        text = f.read()
    have = set(re.findall(r"\$\(MAME_DIR\)/(\S+?) \*/", text))
    have |= set(re.findall(r"/\* (Core/\S+?) \*/", text))
    missing = [s for s in srcs if s not in have]
    print(f"{len(srcs)} in file-list, {len(have)} already in pbxproj, {len(missing)} to add")
    if not missing:
        return 0
    try:
        m = json.load(open(LIBMAP))
        owner, incs, defs = m["owner"], m["incs"], m["defs"]
    except FileNotFoundError:
        owner, incs, descs = {}, {}, {}
        defs = {}
    global_incs = set(re.findall(r'"\$\(MAME_DIR\)/([^"]+)"', text))
    gdef_region = text.split("GCC_PREPROCESSOR_DEFINITIONS")[1][:8000]
    global_defs = {g.strip().strip('"') for g in re.findall(r"([^,\n]+),", gdef_region)}

    def flags_for(s):
        lib = owner.get(s)
        if lib is None or lib == "NO_OWNER":
            if s.startswith("3rdparty/portmidi/"):
                lib = "portmidi"
            elif s.startswith("Core/"):
                # Local iOS sources/snapshots: base flags suffice (they
                # include MAME headers via the global HEADER_SEARCH_PATHS).
                return ""
            else:
                return ""
        ei = [i for i in incs.get(lib, []) if i not in global_incs]
        ed = [d for d in defs.get(lib, []) if d.strip('"') not in global_defs]
        flags = [f'-I"$(SRCROOT)/../../../mame/{i}"' for i in ei] + ed
        if lib in ("ocore_sdl3", "osd_sdl3"):
            drop = re.compile(r"-D(OSD_SDL|SDLMAME_SDL3|SDLMAME_MACOSX|MACOSX_USE_LIBSDL|"
                              r"SDLMAME_UNIX|SDLMAME_DARWIN|USE_NETWORK|OSD_NET_USE_PCAP|"
                              r"USE_OPENGL|USE_XINPUT.*|USE_QTDEBUG|NO_USE_.*|__STDC_.*|"
                              r"BX_CONFIG_DEBUG|BGFX_CONFIG_MAX.*)")
            flags = [f for f in flags if not drop.match(f.strip('"'))]
        if lib == "asmjit":
            flags = ["-include $(SRCROOT)/Core/datarover_asmjit_ios.h"] + flags
        if lib == "flac":
            # <config.h> would resolve to src/emu/config.h (global -Isrc/emu
            # always precedes per-file -I). Prefix-include FLAC's config by
            # relative path, then undef HAVE_CONFIG_H so the TU skips its own.
            flags = ["-I$(SRCROOT)/../../../mame/3rdparty/flac/src/libFLAC/include",
                     "-I$(SRCROOT)/../../../mame/3rdparty/flac/include",
                     "-include $(SRCROOT)/Core/flac_config_prefix.h"] + flags
        if s.endswith(".mm"):
            # bgfx ObjC files use manual retain/release (GENie: no ARC)
            flags = ["-fno-objc-arc"] + flags
        if s == "3rdparty/lsqlite3/lsqlite3.c":
            flags = ["-x", "c++"] + flags
        if lib == "lualibs":
            # GENie project "lualibs": options { "ForceCPP" } — host
            # lfs.o wants __Z-mangled lua_* like luaengine.o.
            flags = ["-x", "c++"] + flags
        if lib == "lua":
            # GENie project "lua": options { "ForceCPP" } (+ `-x c++` for
            # gmake). luaengine.h #defines SOL_USING_CXX_LUA so lua_* refs
            # are C++-mangled; lua TUs must compile as C++ to match.
            flags = ["-DLUA_USE_IOS", "-x", "c++"] + flags
        if lib == "softfloat3":
            # GENie: buildoptions_cpp { "-x c++" } — bochs_ext .c files use
            # C++ functional casts; compile the whole lib as C++.
            flags = ["-x", "c++"] + flags
        if lib in ("utf8proc", "zlib") and "-Dverbose=-1" in flags:
            # -Dverbose poisons the SDK: malloc.h names a parameter `verbose`.
            # utf8proc.c/zlib TUs don't reference `verbose`, so drop it.
            flags = [f for f in flags if f != "-Dverbose=-1"]
        if s.endswith(".mm"):
            # bgfx ObjC files use manual retain/release (GENie: no ARC)
            flags = ["-fno-objc-arc"] + flags
        return " ".join(flags).replace('"', '\\"')

    def proj_path(s):
        # Project-local sources stay project-relative; MAME sources route
        # through $(MAME_DIR).
        return s if s.startswith("Core/") else f"$(MAME_DIR)/{s}"
    ftype = {"cpp": "sourcecode.cpp.cpp", "c": "sourcecode.c.c",
             "mm": "sourcecode.cpp.objcpp", "m": "sourcecode.c.objc"}
    build_lines, ref_lines, phase_lines = [], [], []
    for s in missing:
        u1, u2 = uuid_for("build:" + s), uuid_for("ref:" + s)
        flags = flags_for(s)
        if flags == "SKIP":
            continue
        entry = (f"\t\t{u1} = {{isa = PBXBuildFile; fileRef = {u2} "
                 f"/* {proj_path(s)} */; settings = {{COMPILER_FLAGS = \"{flags}\"; }}; }};\n")
        build_lines.append(entry)
        ref_lines.append(
            f"\t\t{u2} = {{isa = PBXFileReference; explicitFileType = {ftype[s.rsplit('.', 1)[-1]]}; "
            f"path = \"{proj_path(s)}\"; sourceTree = SOURCE_ROOT; }};\n")
        phase_lines.append(f"\t\t\t\t{u1} /* {proj_path(s)} in Sources */,\n")
    text = text.replace("/* End PBXBuildFile section */",
                        "".join(build_lines) + "/* End PBXBuildFile section */", 1)
    text = text.replace("/* End PBXFileReference section */",
                        "".join(ref_lines) + "/* End PBXFileReference section */", 1)
    pat = re.compile(r"isa = PBXSourcesBuildPhase;.*?files = \((.*?)\);", re.S)
    matches = list(pat.finditer(text))
    idx = next((i for i, mm in enumerate(matches) if "datarover_osd.cpp" in mm.group(1)), None)
    if idx is None:
        print("DataRoverCore sources phase not found", file=sys.stderr)
        return 1
    mm = matches[idx]
    text = text[:mm.start(1)] + mm.group(1) + "".join(phase_lines) + text[mm.end(1):]

    # Materialize flac_config_prefix.h with the absolute MAME dir (the
    # #include must be absolute: -Isrc/emu shadows any relative <config.h>).
    import subprocess
    try:
        mamedir = subprocess.run(["xcodebuild", "-project", args.project,
                                  "-scheme", "DataRoverCore", "-configuration", "Release",
                                  "-showBuildSettings"],
                                 capture_output=True, text=True, cwd=os.path.join(HERE, "..")).stdout
        import re as _re
        m = _re.search(r"MAME_DIR = (\S+)", mamedir)
        _md = m.group(1) if m else "$(SRCROOT)/../../../mame"
    except Exception:
        _md = "$(SRCROOT)/../../../mame"
    _pf = os.path.normpath(os.path.join(HERE, "..", "Core", "flac_config_prefix.h"))
    _pt = open(_pf).read()
    if "@MAME_DIR@" in _pt:
        open(_pf, "w").write(_pt.replace("@MAME_DIR@", "/Users/mattkevan/Dev/mame"))
        print("materialized flac_config_prefix.h MAME dir")
    # Project-local Core/ refs stay project-relative
    # (path "Core/..." + sourceTree=SOURCE_ROOT): group-relative paths
    # break the build because these refs are not enclosed in a matching
    # subgroup. Strip any accidental group-relative rewrite.
    for _bad, _good in [
            ('path = "datarover_osd_funcs.cpp"', 'path = "Core/datarover_osd_funcs.cpp"'),
            ('path = "datarover_osd_modules.cpp"', 'path = "Core/datarover_osd_modules.cpp"'),
            ('path = "drivlist.cpp"', 'path = "Core/generated/drivlist.cpp"'),
            ('path = "version.cpp"', 'path = "Core/generated/version.cpp"'),
            ('path = "generated/drivlist.cpp"', 'path = "Core/generated/drivlist.cpp"'),
            ('path = "generated/version.cpp"', 'path = "Core/generated/version.cpp"')]:
        text = text.replace(_bad, _good)
    with open(pbxproj, "w") as f:
        f.write(text)
    print(f"injected {len(missing)} sources into {pbxproj}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
