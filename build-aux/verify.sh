#!/bin/sh
# SPDX-License-Identifier: 0BSD
#
# verify.sh — reproducibility verifier for a published xz release. STUB.
#
# Purpose: given a release tag, fetch the published tarballs and SHA256SUMS
# from the GitHub release, rebuild from git source using the same pinned
# environment as .github/workflows/release.yml, and assert byte-equivalence.
# Also verify the SLSA build provenance attestation against the pinned
# workflow identity so the verifier confirms both "the tarball is a pure
# function of this git commit" AND "this tarball really came out of the
# expected CI workflow."
#
# NOTE: This is a stub. The real implementation lives in a separate
# showcase repo that will demonstrate the end-to-end verification pattern
# for reuse across projects. Leaving this placeholder here so maintainers
# of this fork have a concrete pointer to the verification contract the
# release workflow is designed to satisfy.
#
# Planned usage:
#
#     build-aux/verify.sh v5.8.3
#
# Planned steps:
#   1. Resolve the tag to a git commit and derive SOURCE_DATE_EPOCH from it.
#   2. Pull the runner image / toolchain versions from the workflow file so
#      a mismatch produces a clear error rather than a silent hash diff.
#   3. Run ./autogen.sh --no-po4a and `make dist-gzip dist-xz` with the
#      same TAR_OPTIONS / GZIP / LC_COLLATE environment the CI uses.
#   4. Download the release tarballs and SHA256SUMS via `gh release download`.
#   5. Compare hashes. Report PASS/FAIL with the diffing bytes on failure.
#   6. `gh attestation verify` each tarball against --signer-workflow pinned
#      to this repo's release.yml path.
#
# Until the real implementation lands, this script exits non-zero so nothing
# downstream silently treats it as a successful verification.

set -eu

echo "verify.sh: not yet implemented. See build-aux/verify.sh header for the" >&2
echo "planned verification contract. Real implementation will live in the"   >&2
echo "companion showcase repo."                                               >&2
exit 2
