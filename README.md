# fizzyedit/plugins

The curated **plugin registry** for the [Fizzy](https://github.com/fizzyedit/fizzy) editor.

This repo is a *decentralized* registry. It **builds nothing and hosts no binaries**. Each
plugin is registered once with a small JSON file that points at the author's own
self-hosted `manifest.json`; a scheduled workflow fetches all the manifests and merges them
into a single `plugins/index.json`, published to GitHub Pages at
**<https://plugins.fizzyed.it/index.json>** — which Fizzy's in-app **Plugins** tab reads.

```
registry/<id>.json     ← you submit this once (a pointer to your manifest)
        │  aggregate.py fetches each manifest_url, merges releases
        ▼
plugins/index.json     ← generated + served via Pages; the app reads this
```

## Why this shape

A prebuilt Fizzy plugin is a native dylib valid for exactly one
`(zig version, dvui version, SDK contract)` — captured by the host **ABI fingerprint**. The
fingerprint changes only on a deliberate Fizzy **SDK** bump (not on every app release), so
authors rebuild rarely. Authors host their own binaries and republish their `manifest.json`
on each release (and on each SDK bump); this registry just aggregates. One author's outage
never affects another — the aggregator retains the last-known-good entry.

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
     time you rebuild against a new Fizzy SDK; never rewrite history.
   - `downloads` keys are `os-arch`: `macos-aarch64`, `macos-x86_64`, `linux-x86_64`,
     `windows-x86_64`.
   - `abi_fingerprint` and `sha256` are how the app picks a loadable, verified binary. The
     app shows your plugin as *"needs a rebuild for Fizzy SDK x.y"* until a release matches the
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
   - The PR runs [`validate.yml`](.github/workflows/validate.yml), which checks the entry and
     attempts to fetch your manifest.

Once merged, the next aggregation run (on merge, every 6h, or manual) pulls your manifest into
`index.json`. Update your plugin by republishing **your** `manifest.json` — no PR needed.

## Files

| Path | Role |
|------|------|
| `registry/<id>.json` | Author registration (a pointer to `manifest_url`). |
| `scripts/aggregate.py` | Fetches manifests, validates, merges into `plugins/index.json` (stdlib only). |
| `plugins/index.json` | Generated aggregate index, served via Pages. |
| `plugins/{CNAME,index.html}` | Custom domain + a human landing page. |
| `.github/workflows/aggregate.yml` | Scheduled/triggered regen + Pages deploy. |
| `.github/workflows/validate.yml` | PR validation of registry entries. |
| `docs/manifest.example.json` | A complete example author manifest. |

Run the aggregator locally: `python3 scripts/aggregate.py` (or `--check` to validate without
writing). `file://` manifest URLs work for local testing.
