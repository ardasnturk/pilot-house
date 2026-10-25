# Releasing Remote Code

Everything up to the irreversible steps is scripted. Publishing the GitHub
release and submitting the iOS app for App Review are always done by hand
(D-085).

## 0. One-time setup (account holder)

| What | Where |
|---|---|
| Apple Developer Program membership of team `5JMD3VSD7N` | developer.apple.com |
| Certificates: *Apple Development*, *Apple Distribution*, *Developer ID Application* | Xcode → Settings → Accounts → Manage Certificates |
| App IDs `com.ardasenturk.Pilothouse` (iOS) and `com.ardasenturk.Pilothouse.Mac` | created automatically by Xcode (automatic signing) |
| App record "Remote Code" for `com.ardasenturk.Pilothouse`, primary language English (U.S.), localizations Turkish and German | App Store Connect → Apps → + |
| Notarization credentials | `xcrun notarytool store-credentials pilothouse-notary --apple-id <apple-id> --team-id 5JMD3VSD7N --password <app-specific password>` |
| Optional: App Store Connect API key for unattended uploads | App Store Connect → Users and Access → Integrations; then `ASC_KEY_PATH`, `ASC_KEY_ID`, `ASC_ISSUER_ID` |
| GitHub CLI signed in (`gh auth login`) for the release draft | optional; the script prints the commands otherwise |
| XcodeGen (`brew install xcodegen`) | only to regenerate the project |

## 1. Prepare the version

1. Set `MARKETING_VERSION` in `project.yml` and run `scripts/bootstrap.sh`
   (regenerates translations, icons and `Pilothouse.xcodeproj`).
2. Write `docs/release-notes/<version>.md` and update
   `metadata/ios/*/release_notes.txt`.
3. Run the tests on a Mac:
   ```sh
   scripts/test.sh            # catalogs, package, Mac + iOS schemes
   scripts/test.sh --e2e      # plus the real-Claude test (signed-in `claude`)
   python3 scripts/check-metadata.py
   ```
4. Commit, push, wait for CI to be green.

## 2. Mac app — Developer ID, notarization, DMG

```sh
scripts/build-mac.sh
```

archives the `PilothouseMac` scheme (Release, Developer ID, hardened runtime,
secure timestamp), exports it, verifies the signatures of the app and the
embedded helper, notarizes and staples the app, builds
`dist/RemoteCode-<version>.dmg`, signs, notarizes and staples the DMG and writes
its SHA-256. It also builds the bridge image `dist/Pilothouse-<version>.dmg`
(the same app in a folder named `Pilothouse.app`) that copies up to 1.1.2
need to find the update (D-110).

Check by hand on a second Mac (or a fresh user account): download the DMG,
open it — Gatekeeper must not complain — and run through pairing once.

## 3. GitHub release draft + Homebrew cask

```sh
scripts/prepare-release.sh <version>
```

uploads both DMGs to a **draft** release `v<version>` with the notes from
`docs/release-notes/<version>.md` and writes version + SHA-256 into
`Casks/remote-code.rb`.

Then, deliberately:

1. Review the draft on GitHub and press **Publish release**.
2. Commit and push the cask: `git commit -m "Homebrew cask <version>" Casks/remote-code.rb && git push`.
3. Verify: `brew tap ardasnturk/remote-code https://github.com/ardasnturk/remote-code && brew install --cask remote-code`.

## 4. iOS app — screenshots, TestFlight

```sh
scripts/screenshots.sh                 # iPhone 6.9" + iPad 13", light + dark, EN/TR/DE
BUILD_NUMBER=1 scripts/build-ios.sh    # archive + upload to App Store Connect
```

`screenshots/<language>/<device>-<appearance>/NN-Name.png` are taken from the
demo Mac (D-086). Without a local Mac setup, run the **Screenshots** workflow
(GitHub → Actions → Screenshots → Run workflow) and download the `screenshots`
artifact. The build appears under TestFlight after processing; add
internal testers there. Uploading is reversible (a build can be expired);
`build-ios.sh` never submits anything for review.

## 5. App Store Connect metadata

Copy the texts from `metadata/ios/<locale>/` (or upload them with
`fastlane deliver --skip_binary_upload --metadata_path metadata/ios` if you use
fastlane — the layout is compatible):

| Field | File |
|---|---|
| Name, Subtitle | `name.txt`, `subtitle.txt` |
| Promotional Text, Description, Keywords | `promotional_text.txt`, `description.txt`, `keywords.txt` |
| What's New | `release_notes.txt` |
| Support / Marketing / Privacy Policy URL | `support_url.txt`, `marketing_url.txt`, `privacy_url.txt` |
| Category | `primary_category.txt` (Developer Tools), `secondary_category.txt` (Productivity) |
| Copyright | `copyright.txt` |
| App Review → Notes | `review_information/notes.txt` (sign-in required: **No**) |

Also:

* **App Privacy:** "Data Not Collected" (matches `PrivacyInfo.xcprivacy` and
  `PRIVACY.md`).
* **Age rating:** no objectionable content → 4+ (the app can show arbitrary
  text generated on the user's Mac; answer "Unrestricted Web Access: No").
* **Export compliance:** answered by `ITSAppUsesNonExemptEncryption = NO`
  (D-056).
* **Price:** free. **Availability:** all territories.
* Screenshots: the 6.9" iPhone and 13" iPad sets from step 4.

## 6. Submit for review — manual, after an explicit decision

Pick the processed build, check every locale once more, then press
**Add for Review → Submit**. This step is intentionally not automated.

## 7. After release

* Announce the release; link the App Store page in `README.md`.
* Watch GitHub issues for the first days.
* Start the next `docs/release-notes/<next>.md`.
