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
binding checks `world.props`, accepts exactly two arguments (string ID, table),
and accepts only the string fields `mesh`, `visualEntity`, `physicalEntity`.
The latter is optional; the mesh and visual entity must be depot `.mesh` and
`.ent` paths. It returns an opaque resource-owned model ID string on success,
or nil and a refusal such as `invalid_model_arguments`, `invalid_model_fields`,
`invalid_model_paths` or `model_registration_conflict`. Infinity uses the returned
string, never invents its format, and supplies no physical entity for pool balls.

Each default pair is registered once per pool module start:

```lua
local model, reason = Open77.props.registerModel('pool_ball_1', {
    mesh = 'base\\environment\\decoration\\recreation\\sports\\ball\\ball_c_billiard.mesh',
    visualEntity = 'opx\\pool\\ball_01.ent',
})
```

`opx_pool_assets` 0.3.0 includes all fifteen visual hosts. They are deterministic
derivatives of the supplied, previously rendered object-ball template, each with
one changed vanilla mesh import. Their modified compiled-data buffer is stored
uncompressed; unchanged buffers, offsets, buffer/table/header CRC32 and archive
segment metadata are checked by the asset package tests. Only the original six
legacy host paths and the fifteen new `opx/pool/` paths are allowed in the archive.
No game meshes or textures, DLLs, unrelated alias overrides or legacy gameplay
scripts are added.

A successful registration diagnostic proves the registry accepted the mapping,
not that the engine rendered it. The package requires a fresh game launch through
the launcher. Actual materials, visual scale and removal/rejoin behavior still
require a live game test; native doubles and binary validation do not establish
those visual results.
