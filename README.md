# waybill-action

[![CI](https://github.com/kusari-oss/waybill-action/actions/workflows/ci.yml/badge.svg)](https://github.com/kusari-oss/waybill-action/actions/workflows/ci.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/kusari-oss/waybill-action/badge)](https://scorecard.dev/viewer/?uri=github.com/kusari-oss/waybill-action)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

A GitHub Action that generates **signed** Software Bills of Materials with
[waybill](https://github.com/kusari-oss/waybill). It produces
**CycloneDX 1.6**, **SPDX 2.3** and **SPDX 3.0.1** documents, with SHA-256
hashes, real dependency graphs and evidence.

By default, every SBOM is signed with Sigstore keyless, using your workflow's
own identity. The action always uses the latest waybill release, and verifies
waybill's build provenance before running it.

This action is a hard fork of
[mfahlandt/waybill-action](https://github.com/mfahlandt/waybill-action), created
by Mario Fahlandt, and keeps its history.

## Quick start

```yaml
name: SBOM
on: [push]

permissions:
  contents: read

jobs:
  sbom:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write   # Sigstore keyless signing
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
      - uses: kusari-oss/waybill-action@v1
        with:
          format: cyclonedx-json,spdx-3-json
```

This uploads an `sbom` artifact holding `sbom.cdx.json`, `sbom.spdx3.json`
and a `.sig.bundle.json` Sigstore bundle for each. The job summary shows the
exact command to verify them.

## What the action does

1. **Resolves waybill.** `waybill-version: latest` (the default) is the
   newest non-prerelease of `kusari-oss/waybill`. To pin one, set a tag such
   as `v0.10.0`.
2. **Verifies waybill before running it:**
   - checks the archive's SHA-256 against the release's `SHA256SUMS`;
   - checks its [SLSA build provenance](https://slsa.dev/) with
     `gh attestation verify`. The archive must have been built by
     `kusari-oss/waybill/.github/workflows/release.yml` from that release's tag.

   A failed check stops the action before waybill runs.
3. **Scans** the directory or container image and writes each requested
   format.
4. **Signs** each SBOM (see [Signing](#signing)) and fails if a signature
   it should have written is missing.

## Signing

| `sign` | What you get | Needs |
|---|---|---|
| `keyless` (default) | A Sigstore bundle per SBOM: `<file>.sig.bundle.json`, logged in Rekor, signed as your workflow | `permissions: id-token: write` |
| `key` | CycloneDX: a JSON Signature Format signature inside the document. SPDX: a DSSE envelope, `<file>.sig.json` | `sign-key` (a PEM private key file), and `sign-key-passphrase` if it is encrypted |
| `none` | Unsigned SBOMs, with a warning | nothing |

`keyless` without `id-token: write` fails immediately, before anything is
downloaded, rather than quietly producing an unsigned SBOM.

### Verifying a keyless signature

```sh
cosign verify-blob \
  --bundle sbom.cdx.json.sig.bundle.json \
  --certificate-identity 'https://github.com/<owner>/<repo>/.github/workflows/<workflow>.yml@refs/heads/main' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  sbom.cdx.json
```

The action reports the identity in its `signing-identity` output and the
whole command in `verify-command`.

### Pull requests from forks

GitHub never gives fork pull requests an OIDC token, so they can't sign
keyless. Opt them out explicitly:

```yaml
- uses: kusari-oss/waybill-action@v1
  with:
    sign: ${{ github.event.pull_request.head.repo.fork && 'none' || 'keyless' }}
```

## Usage examples

### Scan a container image

```yaml
- uses: kusari-oss/waybill-action@v1
  with:
    image: 'gcr.io/distroless/static-debian12:latest'
    image-src: 'remote'
    output-file: 'image-sbom.json'
```

### Sign with a static key

```yaml
- run: echo "$SBOM_SIGNING_KEY" > "$RUNNER_TEMP/key.pem"
  env:
    SBOM_SIGNING_KEY: ${{ secrets.SBOM_SIGNING_KEY }}
- uses: kusari-oss/waybill-action@v1
  with:
    sign: key
    sign-key: ${{ runner.temp }}/key.pem
    sign-key-passphrase: ${{ secrets.SBOM_SIGNING_KEY_PASSPHRASE }}
```

### Attach the SBOMs to a release

```yaml
- uses: kusari-oss/waybill-action@v1
  id: sbom
  with:
    format: cyclonedx-json,spdx-3-json
    output-dir: sbom
- uses: softprops/action-gh-release@b4309332981a82ec1c5618f44dd2e27cc8bfbfda # v3.0.0
  with:
    files: |
      ${{ steps.sbom.outputs.sbom-paths }}
      ${{ steps.sbom.outputs.signature-paths }}
```

### Include dev, build and test dependencies

These are excluded by default.

```yaml
- uses: kusari-oss/waybill-action@v1
  with:
    include-dev: 'true'
```

### Anything else waybill can do

Pass extra `waybill sbom scan` arguments, one per line:

```yaml
- uses: kusari-oss/waybill-action@v1
  with:
    args: |
      --root-name
      my-product
```

## Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `path` | Directory to scan (mutually exclusive with `image`) | `.` if `image` is not set |
| `image` | Container image reference or tarball (mutually exclusive with `path`) | |
| `format` | Comma-separated: `cyclonedx-json`, `spdx-2.3-json`, `spdx-3-json` | `cyclonedx-json` |
| `output-file` | Output path when one format is requested | `sbom.json` |
| `output-dir` | Output directory when several formats are requested: `sbom.cdx.json`, `sbom.spdx.json`, `sbom.spdx3.json` | `.` |
| `sign` | `keyless`, `key` or `none` | `keyless` |
| `sign-key` | PEM private key file, for `sign: key` | |
| `sign-key-passphrase` | Passphrase for an encrypted `sign-key` | |
| `waybill-version` | `latest`, or a release tag such as `v0.10.0` | `latest` |
| `verify-provenance` | Verify waybill's SLSA provenance before running it (needs the `gh` CLI) | `true` |
| `include-dev` | Include dev/build/test scoped dependencies | `false` |
| `offline` | Disable outbound network calls for enrichment | `false` |
| `image-src` | Image source order: comma-separated `docker`, `podman`, `remote` | waybill's default |
| `args` | Extra `waybill sbom scan` arguments, one per line | |
| `upload-artifact` | Upload the SBOMs and signatures as a workflow artifact | `true` |
| `artifact-name` | Name of the uploaded artifact | `sbom` |
| `github-token` | Token for downloading waybill and verifying its provenance | `${{ github.token }}` |

## Outputs

| Output | Description |
|--------|-------------|
| `sbom-path` | Absolute path to the (first) SBOM |
| `sbom-paths` | Absolute paths of every SBOM, one per line |
| `signature-paths` | Absolute paths of every detached signature, one per line |
| `signing-identity` | For keyless signing, the certificate identity verifiers must expect |
| `verify-command` | For keyless signing, the `cosign verify-blob` command for the first SBOM |
| `waybill-version` | The waybill release that was used |

## Supported platforms

| Runner | Architecture |
|--------|--------------|
| `ubuntu-latest` | x86_64 |
| `ubuntu-24.04-arm` | aarch64 |
| `macos-latest` | aarch64 (Apple Silicon) |
| `windows-latest` | x86_64 |

CI signs and verifies SBOMs on all four, on every push.

## Upgrading from v0 (or from mfahlandt/waybill-action)

- **Change `uses:`** to `kusari-oss/waybill-action@v1`.
- **Signing is on by default.** Add `permissions: id-token: write` to the job,
  or set `sign: none` to keep the v0 behaviour.
- **`waybill-version` defaults to `latest`** instead of a fixed old release.
- **`format` accepts a comma-separated list.** With several formats, use
  `output-dir` instead of `output-file`.
- The other inputs are unchanged.

## Security

- **Pinned actions.** Every third-party action is pinned by full commit SHA.
- **Verified waybill.** The waybill binary must pass both its SHA-256 check
  and its SLSA provenance check (built by waybill's release workflow from the
  release tag) before it runs.
- **Signed outputs.** Keyless SBOM signatures are recorded in the public
  Sigstore transparency log.
- **Least privilege.** Only `contents: read` and, for keyless signing,
  `id-token: write`.

To report a vulnerability, see [SECURITY.md](SECURITY.md).

## License

[Apache-2.0](LICENSE)
