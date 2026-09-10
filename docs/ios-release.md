# iPhone releases

TestFlight delivers the app over the internet. The phone does not need to be
connected to a build machine. Relevant changes on main trigger the GitHub Actions
`release-ios.yml` workflow. It signs and uploads on a Mac runner, waits for Apple to
report internal testing availability, and publishes an `ios-<commit>` release receipt.
PR checks do not receive signing secrets. The workflow never submits for public
App Store review.

One-time repository setup: secrets `ASC_PRIVATE_KEY`, `ASC_KEY_ID`, `ASC_ISSUER_ID`,
`APPLE_SIGNING_P12` (base64), and `APPLE_SIGNING_PASSWORD`; variable `ASC_APP_ID`.
The runner imports the development signing identity into a temporary keychain and
removes it afterward. The Admin API key handles provisioning and cloud distribution
signing. CI build numbers start above 1000 and increase by workflow run and attempt.

To release from a developer Mac instead:

```sh
python3 scripts/release-ios.py
```

Use Xcode 26 or newer with the developer account added in Xcode Settings → Accounts.
The App Store Connect app record must use `com.carterwatts.assistant`. Create an
internal TestFlight group, add your Apple account, and enable automatic distribution.
On the phone, accept its TestFlight invitation and enable automatic updates.

The command archives Release, uploads for internal testing only, and keeps logs and
artifacts in ignored `build/TestFlight/`. Version comes from `MARKETING_VERSION`;
build number starts at the Git commit count, with Xcode adjusting it on upload.
Apple must process each upload before it becomes available. TestFlight builds expire
after 90 days. This command never submits the app for public App Store review.

Use `--archive-only` to verify a release without uploading. If upload fails after a
successful archive, fix the account issue and retry with `--upload-existing`.

For unattended authentication, set `ASC_KEY_PATH`, `ASC_KEY_ID`, and `ASC_ISSUER_ID`
for an App Store Connect API key with the necessary signing and upload permissions.
Automatic cloud signing requires an Admin key. Alternatively, save `key_path`,
`key_id`, and `issuer_id` in `~/.config/personal-assistant/apple/release.json`
with file permissions `600`. The environment variables override that file as a set.
Keep the private key outside the repository. With no key supplied, Xcode uses its
signed-in developer account. API keys, signing certificates and provisioning profiles
must never be committed.
