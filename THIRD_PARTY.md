# Third-party components

QingType is a derivative of [Squirrel](https://github.com/rime/squirrel), based on
tag `1.1.2` (`876adebaf2f612951dcdca8a591de65401222b9a`). Squirrel's authorship
and GPL-3.0 license are preserved in the source and `LICENSE.txt`.

- **librime**: BSD-3-Clause; API headers are pinned through the `librime` submodule
  at `a251145d3aafa33871824a40bbec04c966bd8b56`. See `librime/LICENSE`.
- **Local runtime and standard schemas**: the development build copies
  `librime.1.dylib`, Rime plugins and SharedSupport data from the locally installed
  Squirrel. CI extracts the public Squirrel 1.1.2 package without installing it.
  Neither path publishes these binaries. Their version, plugin
  licenses and data licenses must be recorded before producing a public release.
- **Xiaohe double pinyin schema**: vendored from
  [rime/rime-double-pinyin](https://github.com/rime/rime-double-pinyin), commit
  `01a13287cbd27819be1c34fa1ddc1b3643d5001b`. Upstream BSD license is included as
  `data/qingtype/LICENSE.double-pinyin`; the simplified QingType variant extends it.
- **Sparkle**: not linked into QingType's command line development build. The
  original Squirrel project and submodule declaration remain for upstream history.

The development build does not use Squirrel's update feed. No public updater,
Developer ID signature, notarization or distribution pipeline is configured yet.

- **Squirrel Panel**: package-manifest, schema-level grammar configuration and
  exclusive deployment lifecycle were informed by the local GPL-3.0 source of
  [wolfprince12/squirrel-Panel](https://github.com/wolfprince12/squirrel-Panel),
  commit `2df9e6fcb4fd1742bf9ba8d296a276ba6ef4d21f`. QingType's import manager
  and deployment report are independently implemented for its dedicated data directory.
- **Yams 5.0.6**: MIT, pinned to
  `0d9ee7ea8c4ebd4a489ad7a73d5c6cad55d6fed3` in `dependencies/Package.resolved`.
  Its license is bundled with both applications. See the upstream package for
  the included libyaml source and its copyright notices.
- **Wanxiang model**: user-imported local data, not bundled with the application.
  Source project: [amzxyz/RIME-LMDG](https://github.com/amzxyz/RIME-LMDG).
  Imported files are copied and SHA-256 checked; the project does not redistribute
  the user's existing model or dictionaries.

- **Input-source cache diagnosis**: the macOS per-application keyboard cache
  repair was independently corroborated by
  [Qingjian issue 346](https://github.com/qingjian-team/qingjian/issues/346).
  The cache backup helper here is independently implemented with a strict
  filename allowlist, reversible backups and symlink/root-boundary tests.

- **Rime Ice**: GPL-3.0, [iDvel/rime-ice](https://github.com/iDvel/rime-ice).
  Optional complete scheme installed by the user from the official release or
  a local folder; not bundled in the app or Git repository. Its license is copied
  with each installation, and a manifest records resource hashes and provenance.
  Reference engine fixture: commit `da1fbe602e38f26db846fa10120ee64c2b0324c0`.
  The official full.zip inspected on 2026-10-27 had SHA-256
  `4e1e677cab1866e7610a350cd85b7bd07d1eeb58aeefff275a1ab3c060515d5e`.
  The package includes third-party dictionaries and Lua/OpenCC resources with
  upstream attribution; audit all component permissions again before public
  redistribution. Current installation retains those source notices.
