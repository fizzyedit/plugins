# fizzyedit/plugins

The curated **plugin registry** for the [Fizzy](https://github.com/fizzyedit/fizzy) editor.

This repo is a *decentralized* registry. It **builds nothing and hosts no binaries**. Each
plugin is registered once with a small JSON file that points at the author's own
self-hosted `manifest.json`; a scheduled workflow fetches all the manifests into a SQLite
database (`registry.db`, the durable source of truth) and exports a static **catalog**,
published to GitHub Pages at **<https://plugins.fizzyed.it/catalog/>** — which Fizzy's
in-app **Plugins** tab reads.

> For the full authoring tutorial — an empty Zig folder through the SDK contract to a tagged
> release — see fizzy's
> [`docs/PLUGINS.md`](https://github.com/fizzyedit/fizzy/blob/main/docs/PLUGINS.md) §6
> "Publishing to the store". This repo covers only the registry/aggregation side of that
> pipeline: registering an already-published plugin so the app can find it.

```
registry/<id>.json        ← you submit this once (a pointer to your manifest)
        │  store ingest — fetches each manifest_url concurrently, upserts
        ▼
registry.db               ← durable history; an author outage keeps last-known-good
        │  store export
        ▼
plugins/catalog/summary.json                      ← every plugin's browse metadata (no releases)
plugins/catalog/<abi_fingerprint>/releases.json   ← one shard per SDK generation; at most one
                                                    release per plugin (the newest for that ABI)
```

## Why this shape

A prebuilt Fizzy plugin is a native dylib valid for exactly one
`(zig version, dvui version, SDK contract)` — captured by the host **ABI fingerprint**. The
fingerprint changes only on a deliberate Fizzy **SDK** bump (not on every app release), so
authors rebuild rarely. Authors host their own binaries and republish their `manifest.json`
on each release (and on each SDK bump); this registry just aggregates. One author's outage
never affects another — `registry.db` retains the last-known-good rows, and release history
is never lost even if an author's manifest drops old entries.

The catalog is **split by fingerprint** so the app's payload stays bounded as the registry
grows: the browse list fetches only `summary.json` (~a few hundred bytes per plugin, no
release data), and each Fizzy build fetches only its *own* fingerprint's shard — which by
construction holds at most one release per plugin, never the full version history.

## Publishing a plugin

1. **Build your plugin** for each target against the Fizzy SDK you support, and publish the
   binaries (e.g. as GitHub Release assets on your own repo). The reusable
   [build action](https://github.com/fizzyedit/plugin-build-action) automates the matrix and
   emits the manifest below.
2. **Host a `manifest.json`** somewhere stable (GitHub Pages or a release asset). Shape:

   ```json
   {
     "id": "markdown",
     "releases": [{
       "version": "0.0.1",
       "min_sdk_version": "0.5.0",
       "abi_fingerprint": "0x0146eaf7c2f9605a",
       "fizzy_sdk_version": "0.5.0",
       "published": "2026-06-26",
       "downloads": {
         "macos-aarch64": { "url": "https://…/markdown-macos-aarch64.dylib", "sha256": "…" },
         "linux-x86_64":  { "url": "https://…/markdown-linux-x86_64.so",     "sha256": "…" },
         "windows-x86_64":{ "url": "https://…/markdown-windows-x86_64.dll",  "sha256": "…" }
       }
     }]
   }
   ```

   - One `releases[]` entry **per `(version, abi_fingerprint)`** — i.e. add a new entry each
     time you rebuild against a new Fizzy SDK; never rewrite history. (The registry keeps a
     durable copy regardless, so users on older SDKs keep matching an older binary.)
   - `downloads` keys are `os-arch`: `macos-aarch64`, `macos-x86_64`, `linux-x86_64`,
     `linux-aarch64`, `windows-x86_64`, `windows-aarch64`.
   - `abi_fingerprint` and `sha256` are how the app picks a loadable, verified binary. The
     app shows your plugin as *"no compatible build in store"* until a release matches the
     user's fingerprint. See [`docs/manifest.example.json`](docs/manifest.example.json).

3. **Open a PR** adding `registry/<your-id>.json`:

   ```json
   {
     "id": "markdown",
     "name": "Markdown",
     "description": "Edit and preview Markdown files.",
     "author": "foxnne",
     "homepage": "https://github.com/foxnne/markdown",
     "tags": ["editor"],
     "manifest_url": "https://foxnne.github.io/markdown/manifest.json"
   }
   ```

   - Required: `id` (must equal the filename stem and your `manifest.id`), `name`,
     `manifest_url`. Optional: `description`, `author`, `homepage`, `tags`.
   - Plugin **ids are globally unique** — the filename convention and the database's
     primary key both enforce it, so pick a non-conflicting id.
   - The PR runs [`validate.yml`](.github/workflows/validate.yml), which checks the entry
     structurally (hard fail) and attempts to fetch your manifest (warning only — your
     hosting being briefly down doesn't block the PR).

Once merged, the next aggregation run (on merge, every 6h, or manual) pulls your manifest into
the catalog. Update your plugin by republishing **your** `manifest.json` — no PR needed.

## Files

| Path | Role |
|------|------|
| `registry/<id>.json` | Author registration (a pointer to `manifest_url`). |
| `store/` | The registry tool (Zig + SQLite): `ingest` / `export` / `validate`. |
| `registry.db` | Generated SQLite database — durable plugin/release history (committed by CI). |
| `plugins/catalog/` | Generated static catalog, served via Pages; the app reads this. |
| `plugins/{CNAME,index.html}` | Custom domain + a human landing page. |
| `.github/workflows/aggregate.yml` | Scheduled/triggered ingest + export + Pages deploy. |
| `.github/workflows/validate.yml` | PR validation of registry entries. |
| `docs/manifest.example.json` | A complete example author manifest. |

Run the tool locally (needs Zig 0.16, Linux/macOS):

```sh
cd store
zig build test                                     # unit tests
zig build run -- validate --root ..                # what the PR gate runs
zig build run -- ingest --root .. --db ../registry.db
zig build run -- export --db ../registry.db --out ../plugins/catalog
```

`file://` manifest URLs work in `ingest`/`validate` for local testing.
