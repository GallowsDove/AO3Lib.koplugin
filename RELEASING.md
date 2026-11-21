# Releases

The version in `_meta.lua` must match the release tag, for example `0.1.0`
and `v0.1.0`. Use patch versions for fixes, minor versions for features, and
major versions for incompatible changes. Prereleases use `0.2.0-rc.1`.

1. Update `_meta.lua`, commit the changes, and push `main`.
2. Wait for **Check and package** to pass in GitHub Actions.
3. Tag that commit and push the tag:

   ```sh
   git tag -a v0.1.0 -m "AO3Lib v0.1.0"
   git push origin v0.1.0
   ```

4. The tag workflow checks the version, runs the tests, and creates a draft
   GitHub release with `AO3Downloader.koplugin.zip` and `SHA256SUMS` attached.
   Review the generated notes, test the ZIP on a device, and publish the draft.
   Tags containing a prerelease suffix are marked as prereleases.

The ZIP extracts directly into KOReader's `plugins` directory. It includes
runtime files, assets and their licenses; README, tests and tools are excluded.
GitHub also displays its automatic source archives; use the attached plugin ZIP
for installation. The README's latest-release link works after the first stable
release is published.

## Local checks

Install LuaJIT, Python 3 with Pillow, and Java for EPUBCheck. Place KOReader and
Bookshelf checkouts next to this repository as `koreader` and
`bookshelf.koplugin`; the workflow pins the tested revisions. No KOReader build
is needed. Then run from this directory:

```sh
python3 tools/check.py --epubcheck /path/to/epubcheck.jar
python3 tools/build_release.py --tag v0.1.0
cd dist
sha256sum -c SHA256SUMS
```

The output is in `dist/`. Without `--epubcheck`, XML and conversion regression
tests still run, but formal EPUBCheck validation is skipped. Optional reference
HTML/EPUB examples beside the repository are compared when available; CI also
validates a generated fixture that requires no external examples.

Rerunning a tag workflow can replace assets on its existing draft. Published
releases are never overwritten: use a new version and tag for corrections.
