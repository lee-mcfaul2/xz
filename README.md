# XZ Utils — secure-build demo fork

> **This is a fork of [tukaani-project/xz](https://github.com/tukaani-project/xz).**
> It is not intended for upstream merge, and the maintainers of the original
> project are not involved. The source code is unchanged from upstream; only
> the release pipeline under `.github/workflows/` has been added to
> demonstrate a build practice.

## Why this fork exists

On 29 March 2024, CVE-2024-3094 was disclosed: a maintainer had quietly
inserted a backdoor into xz-utils. The interesting part — and the part this
fork is built around — is **how** the backdoor was delivered. It was not a
malicious commit visible to anyone reading the git repository. The trigger
was a **source release tarball, uploaded by the maintainer, containing files
that were not present in git** (notably a modified `build-to-host.m4`
autoconf macro). Those extra files executed during `./configure` on
downstream systems and assembled the backdoor from "test fixtures" that
otherwise looked innocuous. Distributions built from the tarball — never
from git — and trusted it on a single maintainer's signature.

This attack class survives even against a diligent code reviewer because
what you read in the git repository is not what you build from. The
defenses are structural, not procedural:

1. **Build the release tarball in public CI, directly from git.** If the
   tarball is produced by an auditable workflow instead of uploaded, a
   maintainer cannot smuggle extra files into it.
2. **Make that build bit-for-bit reproducible.** Then anyone can rebuild
   from git using the same pinned environment and verify that the
   published tarball contains exactly and only what the git source produces.
3. **Attest the result with an identity a third party can independently
   verify.** Not "trust the maintainer," but "verify this tarball was
   produced by *that specific workflow file at that specific git commit*."

This fork is a concrete worked example of items 1–3 on a real,
reasonably-complex autotools project.

## What the release workflow does

See [`.github/workflows/release.yml`](.github/workflows/release.yml). On a
`v*` tag push it:

- **Runs the build inside a SHA-pinned `ubuntu:24.04` Docker container**,
  not directly on GitHub's runner. GitHub's `ubuntu-24.04` label is a
  moving stream of runner images (built from
  [`actions/runner-images`](https://github.com/actions/runner-images),
  not publicly pullable as Docker images). Pinning by container digest
  gives CI and an external verifier access to the same immutable
  artifact.
- **Pins apt sources to `snapshot.ubuntu.com`** at a fixed timestamp
  and version-pins every toolchain package that affects tarball bytes
  (autoconf, automake, libtool, autopoint, gettext, po4a, tar, gzip,
  xz-utils, git). The default `archive.ubuntu.com` only hosts the
  current version of each package, so plain version pins break within
  days. `snapshot.ubuntu.com` keeps historical archive state available
  indefinitely.
- **SHA-pins every third-party action** so the JS side of the workflow
  cannot silently change under us.
- **Derives `SOURCE_DATE_EPOCH`** from the tagged commit's timestamp
  and applies `--clamp-mtime --mtime=@$SOURCE_DATE_EPOCH` in
  `TAR_OPTIONS`, normalizing any build-generated timestamp the
  archive could embed.
- **Runs `validate_map.sh`** before building — the same maintainer
  sanity check upstream's `mydist` target runs before shipping a
  release.
- **Produces the tarball directly from the populated `distdir`** with
  an explicit `tar` invocation rather than `make dist-xz`. Automake's
  `dist-xz` regenerates the staging directory as a prerequisite,
  which would undo an in-place `sed` fix for a
  [`POT-Creation-Date`](https://www.gnu.org/software/gettext/manual/html_node/PO-Files.html)
  non-determinism in the `.po`/`.pot` files that xgettext/po4a stamp
  with wall-clock time despite `SOURCE_DATE_EPOCH`. The `.tar.gz` is
  produced from the same tar by piping through `gzip --no-name --best`
  (automake's `dist-gzip` cannot be made reproducible on modern gzip).
- **Builds the release tarball twice in independent trees** and
  byte-diffs the outputs. If any source of non-determinism slipped
  in, the two builds will not match and the job fails before
  publishing anything. The reproducibility claim is re-proven on
  every release, not asserted and hoped for.
- **Runs a liar-detector check** — a minimum-size floor plus a
  mechanical diff of the tarball's file listing against the
  `distdir`'s file listing. The expected manifest is derived from
  the build system itself, not hardcoded. A pipeline that publishes
  an empty or truncated tarball cannot pass.
- **Generates a SLSA v1 build provenance attestation** for each
  tarball via
  [`actions/attest-build-provenance`](https://github.com/actions/attest-build-provenance).
  Signing is keyless: the workflow's ephemeral OIDC token issues a
  short-lived Fulcio certificate, the attestation is written to the
  public Rekor transparency log, and the signing key is destroyed
  minutes later. No long-lived secret exists for an attacker to steal.
- **Publishes** tarballs, `SHA256SUMS`, and machine-readable
  provenance through the GitHub Release, with human-readable
  verification instructions appended to the release notes.

## Verifying a release

Three checks give complementary evidence. Attestation checks answer
"did this come out of the expected workflow?" and a reproducibility
rebuild answers "is it a pure function of the git source?"

### 1a. Verify the SLSA provenance attestation (`gh`)

```sh
gh attestation verify xz-X.Y.Z.tar.xz \
    --repo <owner>/<repo> \
    --signer-workflow <owner>/<repo>/.github/workflows/release.yml
```

This cryptographically checks that the tarball's SHA-256 was signed by
the exact workflow in this repository at the exact commit the tag
points to. A compromised workflow in a different branch, a malicious
fork, or a replaced release asset all fail this check.

### 1b. Verify the raw-artifact signature (`cosign`)

Each tarball also ships with a `.sigstore` bundle — a detached raw
signature produced by `cosign sign-blob`. Verify it with the
vendor-neutral cosign CLI:

```sh
cosign verify-blob \
    --bundle xz-X.Y.Z.tar.xz.sigstore \
    --new-bundle-format \
    --certificate-identity 'https://github.com/<owner>/<repo>/.github/workflows/release.yml@refs/tags/vX.Y.Z' \
    --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
    xz-X.Y.Z.tar.xz
```

Options 1a and 1b check the same sigstore trust chain (Fulcio
certificate + Rekor transparency log entry); they differ only in
delivery format — GitHub's attestations API vs a file you download
with the release. Either is sufficient on its own.

### 2. Rebuild from scratch and compare

On any machine with Docker — **including a maintainer laptop**,
not only a CI runner — rebuild from the tagged git commit inside
the same pinned container CI used:

```sh
docker run --rm \
    ubuntu@sha256:c4a8d5503dfb2a3eb8ab5f807da5bc69a85730fb49b5cfca2330194ebcc41c7b \
    bash -c '
      # See .github/workflows/release.yml for the authoritative sequence;
      # a stand-alone verify.sh that wraps this is planned.
      apt-get update -qq && apt-get install -y --no-install-recommends ca-certificates
      cat > /etc/apt/sources.list <<APT
deb https://snapshot.ubuntu.com/ubuntu/20260422T180000Z/ noble main restricted universe multiverse
deb https://snapshot.ubuntu.com/ubuntu/20260422T180000Z/ noble-updates main restricted universe multiverse
deb https://snapshot.ubuntu.com/ubuntu/20260422T180000Z/ noble-security main restricted universe multiverse
APT
      rm -f /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list
      apt-get update -qq
      apt-get install -y --no-install-recommends \
        git=1:2.43.0-1ubuntu7.3 curl xz-utils=5.6.1+really5.4.5-1ubuntu0.2 \
        autoconf=2.71-3 automake=1:1.16.5-1.3ubuntu1 libtool=2.4.7-7build1 \
        autopoint=0.21-14ubuntu2 gettext=0.21-14ubuntu2 po4a=0.69-1 \
        build-essential doxygen
      git clone https://github.com/<owner>/<repo> /xz
      cd /xz && git checkout vX.Y.Z
      # ... run the same build steps from release.yml ...
    '
```

Compute `sha256sum` on your rebuilt `.tar.xz` and compare against
`SHA256SUMS` in the release. Matching hashes prove the tarball is a
pure function of the git source at that tag; non-matching hashes mean
somebody's bits are wrong.

The `verify.sh` stub at [`build-aux/verify.sh`](build-aux/verify.sh) is
a placeholder for a one-command wrapper around this. The real
implementation will live in a companion showcase repo.

## Tradeoffs in how the environment is pinned

The workflow uses what we're calling **Option 2** for environment
pinning: pull a SHA-pinned `ubuntu:24.04` base image, and install the
toolchain at build time from `snapshot.ubuntu.com` at a pinned
timestamp with individual package versions pinned. Build-time install
costs apt CPU on every CI run, but nothing is pre-baked and anybody
with Docker can reproduce the same install.

**Option 3 — a pre-built container published to a registry** — would
be strictly better for production use:

1. Maintain a `Dockerfile` that `FROM ubuntu@sha256:...` installs the
   full toolchain from `snapshot.ubuntu.com` at build-image time.
2. Build the image once per toolchain bump, push to GHCR
   (`ghcr.io/<owner>/<repo>/build-env@sha256:...`).
3. The release workflow runs inside that image: zero apt calls at CI
   time, all pinning moves to a single container digest.

Option 3 is cleaner, faster per CI run, and removes any residual
drift within a single digest. It's deferred here for two reasons:

- This fork is a **worked example**, not a production release
  pipeline. The Option 2 flow — the full install happening in plain
  view every run — is more instructive for a reader seeing
  reproducibility concerns for the first time. They can watch each
  step of "how you get from nothing to a hermetic build," which
  Option 3 hides inside an image-build step.
- The second audience this project is pitched at is **the solo
  maintainer compiling world-critical libraries on a laptop**, not
  running a container registry. For that audience, Option 2's
  instructions are directly actionable: one `docker run` command,
  no GHCR account needed. Option 3 is worth graduating to once a
  project has image-registry infrastructure; Option 2 is worth
  adopting on day zero.

Moving from Option 2 to Option 3 when you're ready is additive — you
keep the snapshot URL and version pins, just relocate them from the
workflow's `run:` script to a `Dockerfile`. The pinning strategy
doesn't change; the delivery mechanism does.

## Security properties

What the current workflow **does** defend against:

- The CVE-2024-3094 attack class where a maintainer's release tarball
  contains files not in git. The tarball is produced by CI, not uploaded.
- Drift in CI action code (SHA-pinned actions), container image
  (SHA-pinned `ubuntu:24.04` digest), and toolchain package versions
  (snapshot.ubuntu.com at a fixed timestamp + per-package version pins
  for everything that affects tarball bytes). The hash can be
  re-derived from the git commit + container digest + snapshot URL
  alone, at any point in the future.
- Non-deterministic build inputs smuggled in via a dependency update or
  a slightly-off local build environment. Caught on every run by the
  two-pass self-verification.
- Forgery of the release provenance. Attestation signing identity is
  bound to this specific workflow file, logged to Rekor, and the key
  material is ephemeral.

What it **does not** yet defend against, and how it will:

- **A compromised CI workflow.** Provenance proves "this came out of
  CI," not "this was endorsed by a human maintainer." A separate
  maintainer signature — either `cosign sign-blob` keyless, or a GPG
  signature from a YubiKey-held key — is a complementary claim that
  survives a CI compromise. Both are planned.
- **A compromised git repository.** If the tag points to a malicious
  commit, everything downstream is a faithful reproduction of that
  malice. Branch protection, required reviews, and commit signing
  cover this axis.
- **Downstream consumer verification.** A signature no one checks has
  no value. A companion repo will document the verifier side of this
  story.

## What's in this fork

Upstream source code is unchanged. The additions are:

- `.github/workflows/release.yml` — the reproducible, attested release
  pipeline.
- `build-aux/verify.sh` — stub for end-to-end verification script.
- This `README.md`.

All existing upstream CI (under `.github/workflows/`) is preserved and
continues to run on pushes and PRs.

## Upstream project documentation

For documentation about XZ Utils itself — what the tools do, how to
build and use them, the file format specifications, translation and
bug-reporting workflows — see the original [`README`](README) in this
repository, which is the upstream project's own documentation and is
unmodified here.

## License

XZ Utils is licensed under terms described in [`COPYING`](COPYING).
The workflow additions in this fork are licensed under `0BSD`, matching
the surrounding build-aux conventions and declared in each file's
`SPDX-License-Identifier` header.
