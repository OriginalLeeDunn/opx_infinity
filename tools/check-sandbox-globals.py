#!/usr/bin/env python3
"""Refuse a script that reaches for a global its runtime does not have.

The two runtimes sandbox Lua differently, and neither script is where that is
written down:

  server   open77-base, server/src/Open77.Server.Scripting/Runtime/LuaResourceRuntime.cs
           `Sandbox()` removes io, os, debug, package, dofile, loadfile, load,
           collectgarbage, require.
  client   open77-base, scripting/src/ResourceHost.cpp `OpenSandbox()` removes
           collectgarbage, dofile, load, loadfile, getmetatable, setmetatable, and
           also io, os, debug, package.

A `shared_script` runs in BOTH, so it may use only what both provide. The offline
suite cannot see this: it runs plain `lua5.4`, where every one of these exists, so a
metatable in a shared file passes every test and then refuses the whole resource on
the client -- the session ends with `resource_activation_failed` at activation,
before a single module starts. That is the failure this gate exists for.

Every resource in the tree is checked: the root manifest's scripts, and those of each
folder below it with an `open77.lua` of its own (`extras/opx_sandy_view`, the
Sandevistan's preload, is one). Their scripts run in the same two sandboxes, and
their paths are relative to their own folder.

Usage: tools/check-sandbox-globals.py   (run from the repository root)
Exit 0 clean, 1 on any violation.
"""
import os
import re
import sys

# What each sandbox REMOVES, quoted from the two sources above.
REMOVED = {
    "client": {
        "collectgarbage", "dofile", "load", "loadfile", "getmetatable", "setmetatable",
        "io", "os", "debug", "package",
    },
    "server": {
        "io", "os", "debug", "package", "dofile", "loadfile", "load", "collectgarbage",
        "require",
    },
}

# A script runs in one runtime, or in both when it is shared.
RUNS_IN = {
    "shared_script": ("server", "client"),
    "server_script": ("server",),
    "client_script": ("client",),
}

# `io`, `os`, `debug` and `package` are tables rather than calls.
LIBRARIES = {"io", "os", "debug", "package"}

MANIFEST = re.compile(r'(shared_script|server_script|client_script)\s+"([^"]+)"')


def strip_code(text):
    """Comments and string literals removed, so prose and messages never trip it."""
    text = re.sub(r"--\[\[.*?\]\]", " ", text, flags=re.S)
    text = re.sub(r"--[^\n]*", " ", text)
    # A short string never crosses a line. Letting the class match a newline was a
    # hole: one stray quote (a `'--'` literal whose dashes the comment pass cut)
    # opened a "string" that swallowed hundreds of lines of code, and a removed
    # global inside them -- `getmetatable` in modules/inventory/shared/catalog.lua
    # -- went unseen and raised on every client.
    text = re.sub(r'"(\\.|[^"\\\n])*"', ' "" ', text)
    text = re.sub(r"'(\\.|[^'\\\n])*'", " '' ", text)
    return text


def pattern_for(name):
    if name in LIBRARIES:
        return re.compile(r"(?<![\w.])" + name + r"\s*\.")
    return re.compile(r"(?<![\w.:])" + name + r"\s*\(")


def shadowed(code, name):
    """Whether this file declares the name itself, which hides the global.

    A module is free to call its own `load`: `modules/inventory/server/weapons.lua`
    declares a `local function load(...)` and calls it three times, and none of those
    touch the removed global. Only a file-scope `local function name` or `local
    name =` is recognised, which is the shape every shadow in this pack takes; a
    shadow declared inside one function and reported anyway is answered by renaming.
    """
    if re.search(r"\blocal\s+function\s+" + name + r"\b", code):
        return True
    return re.search(r"\blocal\s+" + name + r"\s*[,=]", code) is not None


# Not ours, or not a resource: the library the suite clones in, and build tooling.
NOT_RESOURCES = {".git", "opx_lib", "node_modules"}


def resources(root):
    """Every folder that is a resource: the root first, then each one below it with an
    `open77.lua` of its own."""
    found = []
    for folder, subfolders, files in os.walk(root):
        subfolders[:] = sorted(d for d in subfolders if d not in NOT_RESOURCES)
        if "open77.lua" in files:
            found.append(folder)
    return found


def main():
    root = os.getcwd()

    problems = []
    checked = 0
    folders = resources(root)
    for folder in folders:
        manifest = open(os.path.join(folder, "open77.lua"), encoding="utf-8").read()
        for kind, relative in MANIFEST.findall(manifest):
            path = os.path.join(folder, relative)
            if not os.path.exists(path):
                continue      # the "every manifest path exists" gate owns missing files
            checked += 1
            shown = os.path.relpath(path, root).replace(os.sep, "/")
            code = strip_code(open(path, encoding="utf-8", errors="replace").read())
            for runtime in RUNS_IN[kind]:
                for name in sorted(REMOVED[runtime]):
                    if shadowed(code, name):
                        continue
                    for match in pattern_for(name).finditer(code):
                        line = code[:match.start()].count("\n") + 1
                        problems.append(
                            f"  {shown}:{line}  `{name}` is removed by the {runtime} sandbox "
                            f"({kind} runs there)")

    print(f"sandbox globals: {checked} manifest script(s) checked in {len(folders)} resource(s)")
    if problems:
        print(f"{len(problems)} violation(s):")
        for problem in sorted(set(problems)):
            print(problem)
        print("\nA shared script may use only what BOTH sandboxes provide.")
        return 1
    print("ok: every script stays inside the globals its runtime provides")
    return 0


if __name__ == "__main__":
    sys.exit(main())
