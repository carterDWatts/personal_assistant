# iPhone releases

TestFlight delivers the app over the internet. The phone does not need to be
connected to the build machine. This command builds on a Mac; it does not require
a cloud build service.

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
Keep the private key outside the repository. With no key supplied, Xcode uses its
signed-in developer account. API keys, signing certificates and provisioning profiles
must never be committed.
