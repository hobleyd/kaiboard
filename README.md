# kAIboard

An iOS keyboard that uses Apple Intelligence, on the device, to suggest and
correct words from the meaning of what you are writing rather than just the
last few letters.

- **Context-aware suggestions.** Completions, corrections and next words come
  from the on-device language model (Foundation Models), merged with an instant
  local dictionary so there is always something to tap.
- **Swipe typing.** Drag across the letters; the closest word is entered at
  once and swapped if the model thinks another reading fits the sentence better.
- **Emoji.** The smiley key opens a picker with every emoji in its default skin
  tone, grouped, with the ones you used lately first. Tap the search field
  above it to find one by name.
- **Fix a word after the fact.** Select a word and the bar offers replacements
  chosen from the text on both sides of it. *Review* asks for more.
- **Learns your words.** Words it doesn't know stop being corrected once you've
  typed them twice, and a word you keep changing into another is offered, then
  applied, in its place. *Review Dictionary* in the app lists both so you can
  delete any.
- **Private.** Nothing leaves the phone. See [Full Access](#full-access) for
  the one thing the keyboard asks it for.

Requires an iPhone with Apple Intelligence (iOS 26 or later).

## Full Access

The keyboard asks for Full Access for one reason only: so it can save the
words it learns to the App Group container (`group.au.com.sharpblue.kaiboard`)
that it shares with the kAIboard app, where *Review Dictionary* reads them.
iOS lets a keyboard write to a shared container only when it has Full Access;
without it, the keyboard has only its own private storage, which the app can't
see.

Nothing else in the keyboard needs Full Access. It makes no network requests,
doesn't read or write the pasteboard, and uses no other service that Full
Access unlocks. Suggestions, swipe typing, Apple Intelligence and emoji all
work the same without it. The only place the keyboard checks `hasFullAccess`
is where it decides which container to keep learned words in.

Leave Full Access off and the keyboard keeps learning, but stores the words
privately, so *Review Dictionary* in the app stays empty. The first time it
runs with Full Access on, it moves what it has already learned into the
shared container. If you turn Full Access off again later, it starts again
with an empty private dictionary.

## Layout

| Path | What it is |
|---|---|
| `core/` | Rust static library: context parsing, typo-aware spelling candidates, swipe decoding, and ranking of the model's answers. |
| `Keyboard/` | The keyboard extension: keys, suggestion bar, editing behaviour. |
| `Shared/` | Swift bridge to the Rust engine and to the language model. |
| `App/` | Container app with setup steps, a playground, and the learned-word dictionary. |
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
| `IOS_PROVISIONING_PROFILE_B64` | App Store profile named `kAIboard App Store` for `au.com.sharpblue.kaiboard`, with the `group.au.com.sharpblue.kaiboard` App Group, base64 |
| `IOS_KEYBOARD_PROVISIONING_PROFILE_B64` | App Store profile named `kAIboard Keyboard App Store` for `au.com.sharpblue.kaiboard.keyboard`, with the same App Group, base64 |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` | App Store Connect API key used for the upload |

All of them are pushed from the `../ansible` repo, which vaults the
certificate, API key and profiles every app shares (`scripts/add_apple_signing.sh`,
`scripts/add_provisioning_profile.sh`). Renew them there rather than with a
hand-run `gh secret set`, or the vault falls behind the secrets.

## Word data

`core/data/` is derived from Peter Norvig's
[web n-gram counts](https://norvig.com/ngrams/), filtered through the macOS
spell checker by `tools/gen_data.swift`.

## Licence

kAIboard is free software, released under the
[GNU General Public License, version 3](LICENSE). The n-gram counts the word
data is derived from are published by Peter Norvig under the MIT licence.
