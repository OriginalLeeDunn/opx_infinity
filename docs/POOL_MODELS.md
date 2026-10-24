# Pool model registry contract

The native reference available during this fix describes op77.148 and does not
list model registration. The deployed, signed Open77 client is **2.50.0+op77.152**.
The full-rack renderer therefore checks the native exists and refuses the table
with an operator diagnostic and friendly notification on older clients.

The inspected client DLL has SHA-256:
`f34f74c9c9c3267bc2fc6bb32fccf940772ecf608aba52c5c58202dd2afde74e`.
It came from the signed core manifest; no modified client executable is shipped.

The Lua `Open77.props.registerModel` binding is registered at VA `0x180792657`
and implemented at VA `0x180759398` (preferred image base `0x180000000`). The
binding checks `props.register`, accepts exactly two arguments (string ID, table),
and accepts only the string fields `mesh`, `visualEntity`, `physicalEntity`.
The manifest must declare `props.register` in addition to `world.props` for
rendering: a deployed client without it returned
`permission_denied:props.register` and stopped pool initialization before creating
the target interaction or any ball props.

`physicalEntity` is optional; the mesh and visual entity must be depot `.mesh` and
`.ent` paths. It returns an opaque resource-owned model ID string on success,
or nil and a refusal such as `invalid_model_arguments`, `invalid_model_fields`,
`invalid_model_paths` or `model_registration_conflict`. Infinity uses the returned
string, never invents its format, and supplies no physical entity for pool balls.

Each default pair is registered once per pool module start:

```lua
local model, reason = Open77.props.registerModel('pool_ball_1', {
    mesh = 'open77\\assets\\opx_infinity\\pool\\ball_01.mesh',
    visualEntity = 'open77\\assets\\opx_infinity\\pool\\ball_01.ent',
})
```

`opx_pool_assets` 0.3.1 includes all fifteen visual hosts. They are deterministic
derivatives of the supplied, previously rendered object-ball template, each with
one changed vanilla mesh import. Their modified compiled-data buffer is stored
uncompressed; unchanged buffers, offsets, buffer/table/header CRC32 and archive
segment metadata are checked by the asset package tests. Only the original six
legacy host paths and the fifteen new `open77/assets/opx_infinity/pool/` paths are allowed in the archive.
No game meshes or textures, DLLs, unrelated alias overrides or legacy gameplay
scripts are added.

A successful registration diagnostic proves the registry accepted the mapping,
not that the engine rendered it. The package requires a fresh game launch through
the launcher. Actual materials, visual scale and removal/rejoin behavior still
require a live game test; native doubles and binary validation do not establish
those visual results.

The path validator at VA `0x1801b90c0` requires both paths to start with
`open77\assets\<registering resource>\`, be at most 240 bytes, end in the
required extension, and contain no traversal or repeated separators. Vanilla
`base/...` mesh paths and the previous `opx/pool/` hosts returned
`invalid_model_paths`. Version 0.3.1 places the actual hosts in Infinity's
namespace and declares fifteen ArchiveXL `resource.link` aliases there for the
vanilla meshes. ArchiveXL ResourceLinkConfig/ResourceLinkExtension source was
checked: a vanilla source key with a list of new paths maps each new path to that
source; it does not replace the source. The existing archive sidecar includes
these links alongside the unchanged streaming cleanup. ArchiveXL must be enabled.
