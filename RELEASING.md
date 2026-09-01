# Releasing

A release is cut by pushing a `v*` tag. `.github/workflows/release.yml` then
builds, signs, notarizes, packages the DMG, uploads it with its Sparkle deltas,
and publishes the appcast.

```bash
# 1. Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.pbxproj.
#    Set both in the Debug and the Release configuration blocks — the workflow
#    fails if the two disagree.
# 2. Commit the bump.
# 3. Tag and push.
git tag v1.4.1
git push origin v1.4.1
```

The tag must match `MARKETING_VERSION`. A mismatch fails the run before anything
is signed, rather than publishing a release whose contents disagree with its name.

To check the signing setup without cutting a release, run the workflow manually
from the Actions tab. It builds and signs, verifies the result, and stops before
notarizing or publishing.

## Required secrets

Set these in Settings → Secrets and variables → Actions. Until all 6 exist the
workflow fails at the step that needs the missing one.

| Secret | What it is |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_P12` | Base64 of your Developer ID Application certificate exported as `.p12`, with its private key |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | The password you set when exporting that `.p12` |
| `SPARKLE_EDDSA_PRIVATE_KEY` | Contents of `.sparkle-keys/eddsa_private_key` |
| `ASC_API_KEY_P8` | Contents of the App Store Connect API key `.p8` file |
| `ASC_API_KEY_ID` | The key's ID, e.g. `A1B2C3D4E5` |
| `ASC_API_ISSUER_ID` | The issuer UUID from the Keys page |

### Developer ID certificate

Xcode → Settings → Accounts → Manage Certificates. Right-click the Developer ID
Application certificate, Export, and give it a password. Then:

```bash
base64 -i Certificates.p12 | pbcopy
```

Paste that as `DEVELOPER_ID_CERTIFICATE_P12` and the password as
`DEVELOPER_ID_CERTIFICATE_PASSWORD`.

Export from Manage Certificates rather than Keychain Access: an Xcode-managed
certificate lives in the data-protection keychain, and an export that omits the
private key produces a `.p12` that imports without error and then cannot sign.

### Sparkle key

```bash
cat .sparkle-keys/eddsa_private_key | pbcopy
```

This has to be the key every previous release was signed with. Generating a new
one publishes a feed that every installed copy rejects, and those users stop
receiving updates permanently — there is no way to recover them except a manual
reinstall. `.sparkle-keys/` is gitignored and exists only on the machine that
made it, so back it up somewhere you will still have it after a disk failure.

### App Store Connect API key

App Store Connect → Users and Access → Integrations → Keys. Create a key with the
Developer role and download the `.p8`; it can only be downloaded once. Copy its
contents as `ASC_API_KEY_P8`, the Key ID as `ASC_API_KEY_ID`, and the Issuer ID
shown above the key list as `ASC_API_ISSUER_ID`.

An API key is used rather than an Apple ID and app-specific password because it
is scoped to notarization and can be revoked on its own.

## What the workflow does

1. Checks the tag against `MARKETING_VERSION`, and that both configurations agree
2. Resolves dependencies strictly from `Package.resolved` and fails if it is stale
3. Runs the tests
4. Imports the certificate into a temporary keychain, deleted when the job ends
5. Builds and signs with `SIGNING_STYLE=manual`
6. Verifies the export is signed and has the hardened runtime enabled
7. Downloads previous DMGs so Sparkle can compute deltas against them
8. Runs `scripts/create-release.sh`: notarize, DMG, sign, notarize the DMG,
   generate the appcast, create the GitHub release, publish the feed
9. Requests every URL in the published appcast and fails if any does not return 200

Step 7 matters more than it looks. `generate_appcast` derives the whole feed from
the DMGs it finds in one directory, so on a runner starting from an empty one it
would emit no deltas and an appcast that had silently dropped every earlier
version.

## Running a release by hand

The workflow calls the same scripts, so the local path still works:

```bash
./scripts/build.sh
./scripts/create-release.sh
```

This needs the Developer ID certificate in your login keychain, a notarytool
keychain profile named `ClaudeIsland`, and `.sparkle-keys/eddsa_private_key`.
`create-release.sh` asks before pushing the appcast; set `ASSUME_YES=true` to
skip the prompt.

## Troubleshooting

**The release job cannot push the appcast or create the release.** The workflow
declares `permissions: contents: write`, which overrides the repository default.
If a push is still refused, check Settings → Actions → General → Workflow
permissions; this repository's default is read-only, and an organisation policy
can stop a workflow from raising it. Setting it to "Read and write permissions"
resolves it.

**`No signing certificate "Developer ID Application" found`.** The `.p12` went in
without its private key. Re-export it from Xcode → Settings → Accounts → Manage
Certificates rather than from Keychain Access.

**Notarization is rejected for the hardened runtime.** `build.sh` passes
`ENABLE_HARDENED_RUNTIME=YES`, and the workflow verifies it on the exported app
before submitting, so this points at a change to the build settings.

**Sparkle reports the update is not signed.** The `SPARKLE_EDDSA_PRIVATE_KEY`
secret does not match `SUPublicEDKey` in `ClaudeIsland/Info.plist`.
`create-release.sh` fails the run when `generate_appcast` produces an unsigned
feed, but it cannot tell that a validly signed feed was signed with the wrong key.

**The feed advertises files that 404.** The final step catches this. Every
enclosure URL has to be a release asset; `scripts/rewrite-appcast-urls.py` puts
them there and refuses to write a feed where any is not.
