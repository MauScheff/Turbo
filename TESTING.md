# Testing Guide

This file captures repo-specific test command rules that are easy to get subtly wrong.

## Swift Testing selectors

`TurboTests` uses Swift Testing (`import Testing`, `@Test`), not classic XCTest method selectors. A raw `xcodebuild -only-testing` selector can build successfully while selecting zero Swift Testing tests.

Preferred targeted command:

```bash
just swift-test-target audioOutputPreferenceCyclesBetweenSpeakerAndPhone
```

The wrapper resolves the Swift Testing suite, invokes `xcodebuild` with the exact `-only-testing` selector, uses the repo's serialized simulator lane, and fails if the requested Swift Testing function name never appears in the output. Use it when proving a focused Swift regression.

Preferred full-bundle command:

```bash
just swift-test-suite
```

The full-suite wrapper runs the entire `TurboTests` bundle, reuses the repo's serialized simulator lane, writes an `.xcresult`, and fails if the result bundle reports zero executed tests. Use it when you want all app-side unit/integration tests rather than one focused Swift Testing function or the end-to-end simulator scenario catalog.

If raw `xcodebuild` is unavoidable, include the suite type and the trailing function parentheses:

```bash
xcodebuild test \
  -project Turbo.xcodeproj \
  -scheme BeepBeep \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  '-only-testing:TurboTests/TurboTests/audioOutputPreferenceCyclesBetweenSpeakerAndPhone()' \
  -skip-testing:TurboUITests \
  CODE_SIGNING_ALLOWED=NO
```

Selector shape:

```text
TurboTests/<Swift Testing suite type>/<test function>()
```

Examples:

```text
TurboTests/TurboTests/audioOutputPreferenceCyclesBetweenSpeakerAndPhone()
TurboTests/HatTilingTests/levelTwoHatTextureIsDeterministic()
```

Do not use partial or XCTest-style selectors for Swift Testing proofs:

```text
-only-testing:TurboTests/
-only-testing:TurboTests/TurboTests/<test function>
-only-testing:TurboTests/<test function>
```

Those forms can return a successful build/test command with zero selected Swift Testing tests.

For proof, require at least one of:

- `just swift-test-target <name>` exits successfully
- `just swift-test-suite` exits successfully
- the log contains Swift Testing lines such as `Test <name>() started` and `Test <name>() passed`
- an xcresult summary reports `totalTestCount` greater than zero:

```bash
xcrun xcresulttool get test-results summary --path <ResultBundle>.xcresult
```

Do not count a successful build, `Testing started`, or a classic XCTest summary alone as proof that the intended Swift Testing test ran.
