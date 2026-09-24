# Branch and release rules

This file applies to the entire repository.

## Branch ownership

- `upstream/main` is the source of upstream changes. Keep `dev` as a clean, fast-forward-only mirror of upstream; do not merge fork features into `dev`.
- Develop fork changes on `feature/*` branches based on the appropriate upstream baseline. Existing feature and release branches and tags are historical records; do not delete, rebase, force-push, or retag them without an explicit request.
- Integrate upstream and fork features on `release/*` branches. Every new release must retain both cloud-storage push and the in-app updater. Check behavior and tests, not only the presence of old commits or files.
- `main` is the stable, published fork line. Do not merge a release branch into `main` while its GitHub Release is a draft or prerelease. Once the exact release commit has a published, non-prerelease GitHub Release with verified artifacts, merge it into `main` with ordinary history-preserving Git operations. Governance-only changes may be applied to `main` without changing the app version or publishing a release.

## Build and publication

- Pushes to `dev` and `feature/*` do not build release packages. Pushes to `release/*` run Android, Windows, and macOS verification/build workflows and upload temporary Actions artifacts; CI must not create a tag or GitHub Release from a branch push.
- Before publishing, verify Flutter analysis and tests, all three platform artifacts, the Android package/versionCode/signing certificate, and the macOS/Windows packaging notes. Ensure the new Android versionCode exceeds the previous stable release so the in-app updater can install it.
- Publish deliberately from the verified release commit: create an immutable version tag pointing to that commit, upload the checked Android APK, Windows ZIP, macOS DMG, and checksums, and write release notes including the fork's incompatible Android signing certificate and unsigned desktop limitations. Only mark a release stable after verification; a prerelease must not enter `main`.
- After publication, verify the tag still points to the reviewed commit and the published release is not a draft or prerelease, then merge the release branch into `main`. Never use a `main` push as a publication trigger.
- Do not commit signing keys, tokens, credentials, local configuration, build output, or user data. Keep release signing material in GitHub Actions secrets.

## Validation

- Before committing, run `git diff --check` and inspect staged files. For app changes, run `flutter analyze` and `flutter test` where Flutter is available; otherwise report that these checks were not run locally and rely on the release CI result.
- When editing workflows, validate their YAML and confirm `main`, `dev`, and feature pushes cannot publish a release.
