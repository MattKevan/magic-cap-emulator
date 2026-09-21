#!/usr/bin/env python3
"""Inject MAME file-list sources into the xcodegen-generated pbxproj, then
re-apply the project's documented post-generation fix.

Both passes run after `xcodegen generate` and both are idempotent:

1. Inject the core targets' MAME sources (Core/file-list.txt, MAME_DIR-
   relative) as explicit PBXBuildFile/PBXFileReference entries with
   $(MAME_DIR) paths — xcodegen has no file-list include mechanism. Every
   Sources phase that compiles Core/datarover_osd.cpp is a core target and is
   filled; sources already present are skipped, generated build-file UUIDs are
   namespaced per target, and Core/datarover_carboncore_stubs.cpp is left out
   of every target that is not DataRoverCore (it stands in for the Carbon
   symbols the macOS core links against for real).

Per-file COMPILER_FLAGS carry each owning GENie lib's local defines/includes
(mirroring build/projects/sdl3/mamedatarover/gmake-osx-clang/*.make) so the
global target settings stay shadowing-safe, and they are identical for both
core targets so the core stays one behaviour surface:
- HAVE_CONFIG_H + FLAC include dirs live ONLY on flac/ entries (a global
  <config.h> would resolve to src/emu/config.h for every other C TU).
- asmjit/ entries get -include $(SRCROOT)/Core/datarover_asmjit_ios.h
  (upstream gates sys_icache_invalidate's header on TARGET_OS_OSX).
- ocore/osd entries drop the SDL OSD defines (headless: no SDL).

2. Strip the -ObjC flag xcodegen appends to the DataRover app target's
OTHER_LDFLAGS because that target links a static-library target; xcodegen
re-adds it on every generate, and the committed pbxproj must stay the
pipeline output with this one documented exception (see project.yml).

The per-lib compile map comes from gen_mame_libmap.py.

Usage: python3 scripts/inject_mame_sources.py [--project DIR] [--libmap PATH]
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

sys.path.insert(0, HERE)
import gen_mame_libmap  # noqa: E402  (sibling script, same directory)

# TUs that build only against the iOS core. datarover_carboncore_stubs.cpp
# defines the Pasteboard*/kUTType* symbols iOS lacks; those definitions
# collide with the real Carbon ones the macOS core links, so the file joins
# every core target's Sources phase except DataRoverCore's.
IOS_ONLY = {"Core/datarover_carboncore_stubs.cpp"}

# The one place the two cores cannot share a compiler mode: on macOS,
# 3rdparty/bgfx/src/renderer_vk.cpp imports <Cocoa/Cocoa.h> and friends under
# BX_PLATFORM_OSX, which only compiles as Objective-C++. Upstream compiles the
# whole bgfx project that way for targetos macosx (scripts/src/3rdparty.lua,
# project "bgfx"); GENie cannot scope a buildoption per file, we can, so this
# is the only per-file flag that differs between the cores (it changes the
# language mode, not the -D set: the compiled configuration is identical).
MAC_TARGETS = {"DataRoverCoreMac"}
OBJCPP_ON_MAC = {"3rdparty/bgfx/src/renderer_vk.cpp"}


def uuid_for(key):
    return hashlib.sha1(("datarover:" + key).encode()).hexdigest()[:24].upper()


def load_file_list():
    path = os.path.normpath(os.path.join(HERE, "..", "Core", "file-list.txt"))
    with open(path) as f:
        return [ln.strip() for ln in f if ln.strip()]


def default_mame_dir(project):
    """MAME_DIR default: a `mame` sibling of the repo root (see project.yml)."""
    return os.path.normpath(os.path.join(os.path.dirname(project),
                                         "..", "..", "..", "mame"))


# Post-generation fix: xcodegen appends -ObjC to OTHER_LDFLAGS for a target
# that links a static-library target (here DataRoverCore) and re-adds it on
# every `xcodegen generate`. The app target's block is the one carrying its
# -lc++ link flag. Commit 3594f42 removed the flag deliberately.
OBJC_LDFLAGS = re.compile(r"OTHER_LDFLAGS = \((.*?)\);", re.S)
OBJC_FLAG_LINE = re.compile(r'^[ \t]*"-ObjC",\n', re.M)


def strip_objc_flag(text):
    """Delete xcodegen's auto -ObjC from the app target's OTHER_LDFLAGS.

    Pure: returns (text, blocks_stripped) and leaves writing to the caller.
    """
    stripped = []

    def fix(m):
        block = m.group(1)
        if '"-lc++"' in block and OBJC_FLAG_LINE.search(block):
            stripped.append(block)
            return f"OTHER_LDFLAGS = ({OBJC_FLAG_LINE.sub('', block)});"
        return m.group(0)

    return OBJC_LDFLAGS.sub(fix, text), len(stripped)


def load_libmap(path, mame_dir):
    """Read the per-lib map, regenerating it from the fork when missing."""
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        pass
    print(f"{path} missing; regenerating from {mame_dir} "
          f"(gen_mame_libmap.py)", file=sys.stderr)
    data = gen_mame_libmap.generate(mame_dir)
    with open(path, "w") as f:
        json.dump(data, f, indent=1, sort_keys=True)
    return data


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", default=DEFAULT_PROJ)
    ap.add_argument("--libmap", default=LIBMAP)
    ap.add_argument("--mame-dir", default=os.environ.get("MAME_DIR"))
    args = ap.parse_args()
    mame_dir = args.mame_dir or default_mame_dir(args.project)
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
        # Nothing to inject; still re-apply the post-generation fix, so the
        # tree is only left alone when it already matches the committed file.
        text, stripped = strip_objc_flag(text)
        if stripped:
            with open(pbxproj, "w") as f:
                f.write(text)
            print(f'stripped "-ObjC" from {stripped} OTHER_LDFLAGS block(s)'
                  f" in {pbxproj}")
        return 0
    m = load_libmap(args.libmap, mame_dir)
    owner, incs, defs = m["owner"], m["incs"], m["defs"]
    global_incs = set(re.findall(r'"\$\(MAME_DIR\)/([^"]+)"', text))
    gdef_region = text.split("GCC_PREPROCESSOR_DEFINITIONS")[1][:8000]
    global_defs = {g.strip().strip('"') for g in re.findall(r"([^,\n]+),", gdef_region)}

    def flags_for(s):
        lib = owner.get(s)
        if lib is None or lib == "NO_OWNER":
            if s.startswith("3rdparty/portmidi/"):
                lib = "portmidi"
            elif s.startswith("Core/"):
                # Local sources/snapshots: base flags suffice (they include
                # MAME headers via the global HEADER_SEARCH_PATHS).
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

    # The core targets' Sources phases are the ones compiling
    # datarover_osd.cpp; the phase's owning PBXNativeTarget names the target
    # whose per-target exclusions apply.
    owner_pat = re.compile(
        r"[A-F0-9]{24} /\* (\w+) \*/ = \{\s*isa = PBXNativeTarget;.*?"
        r"buildPhases = \((.*?)\);", re.S)
    phase_owner = {}
    for tm in owner_pat.finditer(text):
        for pid in re.findall(r"([A-F0-9]{24}) /\*", tm.group(2)):
            phase_owner[pid] = tm.group(1)
    phase_pat = re.compile(
        r"([A-F0-9]{24}) /\* Sources \*/ = \{\s*isa = PBXSourcesBuildPhase;"
        r".*?files = \((.*?)\);", re.S)
    phases = [mm for mm in phase_pat.finditer(text)
              if "datarover_osd.cpp" in mm.group(2)]
    if not phases:
        print("no core sources phase found (nothing compiles "
              "datarover_osd.cpp)", file=sys.stderr)
        return 1

    build_lines, ref_lines, refs, spliced = [], [], set(), []
    for mm in phases:
        target = phase_owner.get(mm.group(1))
        if target is None:
            print(f"sources phase {mm.group(1)} belongs to no PBXNativeTarget",
                  file=sys.stderr)
            return 1
        added, phase_lines = [], []
        for s in missing:
            if target != "DataRoverCore" and s in IOS_ONLY:
                continue
            flags = flags_for(s)
            if target in MAC_TARGETS and s in OBJCPP_ON_MAC:
                # Non-ARC, like every other ObjC file here and like GENie's
                # macOS build of bgfx (its ALL_OBJCPPFLAGS carry no -fobjc-arc);
                # ARC rejects the manual (NSWindow*)(void*) bridge in this file.
                flags = f"-x objective-c++ -fno-objc-arc {flags}".strip()
            if flags == "SKIP":
                continue
            u1, u2 = uuid_for(f"{target}:build:{s}"), uuid_for("ref:" + s)
            build_lines.append(
                f"\t\t{u1} = {{isa = PBXBuildFile; fileRef = {u2} "
                f"/* {proj_path(s)} */; settings = {{COMPILER_FLAGS = \"{flags}\"; }}; }};\n")
            if u2 not in refs:
                refs.add(u2)
                ref_lines.append(
                    f"\t\t{u2} = {{isa = PBXFileReference; explicitFileType = "
                    f"{ftype[s.rsplit('.', 1)[-1]]}; path = \"{proj_path(s)}\"; "
                    f"sourceTree = SOURCE_ROOT; }};\n")
            phase_lines.append(f"\t\t\t\t{u1} /* {proj_path(s)} in Sources */,\n")
            added.append(s)
        spliced.append((mm, target, added, "".join(phase_lines)))
    # Splice back-to-front so the offsets of the earlier phases stay valid.
    for mm, _target, _added, lines in reversed(spliced):
        text = text[:mm.start(2)] + mm.group(2) + lines + text[mm.end(2):]
    text = text.replace("/* End PBXBuildFile section */",
                        "".join(build_lines) + "/* End PBXBuildFile section */", 1)
    text = text.replace("/* End PBXFileReference section */",
                        "".join(ref_lines) + "/* End PBXFileReference section */", 1)

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
    text, stripped = strip_objc_flag(text)
    with open(pbxproj, "w") as f:
        f.write(text)
    for _mm, target, added, _lines in spliced:
        print(f"injected {len(added)} sources into {target}")
    if stripped:
        print(f'stripped "-ObjC" from {stripped} OTHER_LDFLAGS block(s)'
              f" in {pbxproj}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
