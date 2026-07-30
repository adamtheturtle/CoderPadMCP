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

- `DEVELOPER_ID_APP_CERT_P12_BASE64`: base64-encoded Developer ID
  Application `.p12`;
- `DEVELOPER_ID_APP_CERT_PASSWORD`: password used when exporting the `.p12`;
- `ASC_KEY`: base64-encoded App Store Connect API `.p8` key;
- `ASC_KEY_ID`: the API key's ID;
- `ASC_ISSUER_ID`: the API key's issuer UUID.

These names match the signing credentials used by `coderpad-macos`.

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
