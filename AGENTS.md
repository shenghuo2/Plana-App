# Branch and release rules

This file applies to the entire repository.

## Branch ownership

- `upstream/main` is the source of upstream changes. Keep `dev` as a clean, fast-forward-only mirror of upstream; do not merge fork features into `dev`.
- Develop fork changes on `feature/*` branches based on the appropriate upstream baseline. Existing feature and release branches and tags are historical records; do not delete, rebase, force-push, or retag them without an explicit request.
- Integrate upstream and fork features on `release/*` branches. Every new release must retain both cloud-storage push and the in-app updater. Check behavior and tests, not only the presence of old commits or files.
- `main` is the stable, published fork line. Do not merge a release branch into `main` while its GitHub Release is a draft or prerelease. Once the exact release commit has a published, non-prerelease GitHub Release with verified artifacts, merge it into `main` with ordinary history-preserving Git operations. Governance-only changes may be applied to `main` without changing the app version or publishing a release.
- Desktop platforms (`feature/desktop-platforms`, Windows/macOS builds) are retired from this repository and maintained in a separate repository: do not integrate `feature/desktop-platforms`, desktop platform directories (`macos/`, `windows/`), or `.github/workflows/build-desktop.yml` into future `release/*` branches; keep existing `feature/desktop-platforms` and past release branches/tags only as historical records.

## Build and publication

- Pushes to `dev` and `feature/*` do not build release packages. Pushes to `release/*` run Android verification and APK build workflows only (Windows and macOS builds are retired from this repository) and upload temporary Actions artifacts; CI must not create a tag or GitHub Release from a branch push.
- Before publishing, verify Flutter analysis and tests, and the Android APK artifact (package, versionCode, and signing certificate). Ensure the new Android versionCode exceeds the previous stable release so the in-app updater can install it.
- Publish deliberately from the verified release commit: create an immutable version tag pointing to that commit, upload the checked Android APK and checksums, and write release notes including the fork's incompatible Android signing certificate. Only mark a release stable after verification; a prerelease must not enter `main`.
- After publication, verify the tag still points to the reviewed commit and the published release is not a draft or prerelease, then merge the release branch into `main`. Never use a `main` push as a publication trigger.
- Do not commit signing keys, tokens, credentials, local configuration, build output, or user data. Keep release signing material in GitHub Actions secrets.

## Validation

- Never bypass git hooks with `--no-verify`. Enable the versioned hooks via `git config core.hooksPath .githooks`.
- Before committing, run `git diff --check`, inspect `git status` and `git diff --cached`, and run the project's formatter/linter (`dart format`, `flutter analyze`) and relevant `flutter test` suites where Flutter is available; otherwise report that Flutter checks were not run locally and rely on the release CI result.
- When editing workflows, validate their YAML and confirm `main`, `dev`, and feature pushes cannot publish a release.

## Git Commit Conventions

Follow these rules strictly for every commit (never bypass git hooks with `--no-verify`):

### 1. Commit Message Format
- **Format**: `<type>(<scope>): <中文简述>` (`scope` is optional; append `!` before `:` for breaking changes; `Merge ` and `Revert ` headers are exempt).
- **Allowed `type`**:
  - `feat`: new feature
  - `fix`: bug fix
  - `docs`: documentation only
  - `style`: formatting/whitespace with no logic change
  - `refactor`: code restructuring without changing behavior
  - `perf`: performance improvement
  - `test`: adding or updating tests
  - `build`: build system or external dependencies
  - `ci`: CI/CD configuration or scripts
  - `chore`: tooling, config, or maintenance tasks
- **Language**: Both subject and body MUST be written in **Chinese** (the description must contain Chinese characters; standard git trailers such as `Co-Authored-By:` are exempt).
- **Scope & Granularity**:
  - Use a concise lowercase module/area name matching `[a-z0-9_/-]+` (e.g., `auth`, `gallery`, `update`, `repo`); omit `scope` for cross-cutting changes.
  - Keep **one logical change / one module per commit**; split unrelated changes into separate commits.
- **Examples**:
  - `feat(auth): 新增 OAuth2 登录回调与令牌刷新`
  - `fix(api/orders): 修复并发下单时的库存扣减竞态`
  - `refactor(storage): 抽离对象存储客户端初始化逻辑`
  - `docs: 补充本地调试与环境变量说明`

### 2. Staging & Hygiene Rules
- **Never stage**:
  - Runtime data, local secrets/credentials (`*.jks`, `*.keystore`, `key.properties`, `local.properties`, `.env*` except templates, private keys), or generated artifacts (`build/`, `.dart_tool/`, `*.apk`, `macos/`, `.github/workflows/build-desktop.yml`, `docs/`);
  - Temporary summary/report files (e.g., `*_SUMMARY.md`, `SUMMARY.md`);
  - Unrelated unstaged edits in the working tree.
- **Code & comment hygiene** (on added/modified lines):
  - Retain this repository's upstream **Chinese** inline comment and log message convention (consistent with existing Dart/Kotlin code across `Plana-App`).
  - Update relevant docs and tests whenever public behavior, config, or APIs change.

### 3. Pre-Commit Verification
Before running `git commit`:
1. Run the project's formatter (`dart format`) and linter (`flutter analyze` / `dart analyze`) on all staged/modified files and resolve all errors.
2. Run relevant unit/integration tests covering the changed modules (`flutter test`).
3. Inspect `git status` and `git diff --cached` to confirm only intended files are staged.

### 4. Local Hook & CI Enforcement
Enforcement is active both locally via versioned `.githooks/` (`git config core.hooksPath .githooks`) and in GitHub Actions via `.github/workflows/commit-guard.yml` (shared logic in `.githooks/validate.py`; `dev` and historical upstream/release baselines are exempt):
- `commit-msg`: validates subject against `^(feat|fix|docs|style|refactor|perf|test|build|ci|chore)(\([a-z0-9_/-]+\))?!?: .+$`, requires at least one CJK character (`[\u4e00-\u9fff]`) in the description and any non-trailer body text, and exempts `Merge ` / `Revert ` headers.
- `pre-commit`: blocks forbidden paths/report files (`*_SUMMARY.md`, secrets, build outputs, retired desktop files), scans added lines for private key headers, checks `git diff --cached --check`, validates workflow YAML / Python hook syntax, and runs `dart format` + `dart analyze` on staged Dart files.
- `ci-check` (`.github/workflows/commit-guard.yml`): re-verifies commit messages, forbidden paths, private key headers, whitespace/conflict markers, and workflow/hook syntax across new non-upstream commits pushed or PR'd to `main`, `feature/**`, and `release/**`.
