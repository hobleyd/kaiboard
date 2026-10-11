# kAIboard

An iOS keyboard that uses Apple Intelligence, on the device, to suggest and
correct words from the meaning of what you are writing rather than just the
last few letters.

- **Context-aware suggestions.** Completions, corrections and next words come
  from the on-device language model (Foundation Models), merged with an instant
  local dictionary so there is always something to tap.
- **Swipe typing.** Drag across the letters; the closest word is entered at
  once and swapped if the model thinks another reading fits the sentence better.
- **Fix a word after the fact.** Select a word and the bar offers replacements
  chosen from the text on both sides of it. *Review* asks for more.
- **Private.** Nothing leaves the phone and the keyboard does not ask for Full
  Access.

Requires an iPhone with Apple Intelligence (iOS 26 or later).

## Layout

| Path | What it is |
|---|---|
| `core/` | Rust static library: context parsing, typo-aware spelling candidates, swipe decoding, and ranking of the model's answers. |
| `Keyboard/` | The keyboard extension: keys, suggestion bar, editing behaviour. |
| `Shared/` | Swift bridge to the Rust engine and to the language model. |
| `App/` | Container app with setup steps and a playground. |
| `tools/` | Scripts that regenerate the dictionary and the app icon. |

## Building

You need Xcode 26 or later, [Rust](https://rustup.rs) and
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
xcodegen generate
open kAIboard.xcodeproj
```

Run the `kAIboard` scheme on a phone, then add the keyboard under Settings →
General → Keyboard → Keyboards. The Rust engine has its own tests:
`cd core && cargo test`.

## Releases

Every push to `main` runs `.github/workflows/release.yml`, which tests the
engine, builds the app, and uploads a signed build to TestFlight. The build
number is the workflow run number. The upload needs these repository secrets:

| Secret | Contents |
|---|---|
| `IOS_DIST_CERT_P12` | Apple Distribution certificate and key, as base64 of the `.p12` |
| `IOS_DIST_CERT_PASSWORD` | Password of that `.p12` |
| `KEYCHAIN_PASSWORD` | Any password; protects the temporary keychain on the runner |
| `IOS_PROVISIONING_PROFILE_B64` | App Store profile named `kAIboard App Store` for `au.com.sharpblue.kaiboard`, base64 |
| `IOS_KEYBOARD_PROVISIONING_PROFILE_B64` | App Store profile named `kAIboard Keyboard App Store` for `au.com.sharpblue.kaiboard.keyboard`, base64 |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` | App Store Connect API key used for the upload |

## Word data

`core/data/` is derived from Peter Norvig's
[web n-gram counts](https://norvig.com/ngrams/), filtered through the macOS
spell checker by `tools/gen_data.swift`.

## Licence

kAIboard is free software, released under the
[GNU General Public License, version 3](LICENSE). The n-gram counts the word
data is derived from are published by Peter Norvig under the MIT licence.
