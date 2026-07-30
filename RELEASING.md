# Releasing CoderPadMCP

Pushing a semantic-version tag runs the
[`Release`](.github/workflows/release.yml) workflow. It tests the tagged source,
builds the standalone `coderpad-mcp` executable, and publishes:

- a signed and notarized universal macOS archive;
- a Linux x86_64 archive with the Swift runtime statically linked;
- a SHA-256 checksum alongside each archive.

The version in `Sources/CoderPadMCP/ReleaseVersion.swift` must match the tag.
Tags may be written as `1.2.3` or `v1.2.3`.

## Repository secrets

Configure these GitHub Actions secrets before publishing:

- `MACOS_CERTIFICATE_BASE64`: base64-encoded Developer ID Application `.p12`;
- `MACOS_CERTIFICATE_PASSWORD`: password used when exporting the `.p12`;
- `MACOS_SIGNING_IDENTITY`: full Developer ID Application certificate identity;
- `APPLE_ID`: Apple ID used for notarization;
- `APPLE_TEAM_ID`: Apple Developer team ID;
- `APPLE_APP_SPECIFIC_PASSWORD`: app-specific password for the Apple ID.

For example, encode the certificate on macOS with:

```sh
base64 -i DeveloperIDApplication.p12 | pbcopy
```

## Publishing

1. Update `coderPadMCPVersion` and merge the change.
2. Create and push the matching tag.
3. Wait for the Release workflow to publish the GitHub Release.

The workflow can be run manually with an existing tag to retry or backfill a
release. Existing release assets are replaced, making retries safe.
