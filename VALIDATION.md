# Local validation — 2026-10-27 — QingType 0.4.1

Environment: Apple Silicon, macOS 27.0.1, Swift 6.4. The machine now has Xcode
27.1 selected at `/Applications/Xcode.app/Contents/Developer`. The initial
prototype was built earlier with Command Line Tools alone.

## Native candidate geometry — 0.4.1

The user's two Retina (2x) screenshots show QingType's 32 px candidate glyphs
against Apple Pinyin's 28 px glyphs. Default font size is now 16 pt instead of
18, with a 29 pt capsule instead of 32. Placement shifts the panel 16 pt left
of the marked-text origin and leaves a 6 pt vertical gap; the intended alignment
is the first candidate text, with the panel edge extending left. Horizontal
padding and the separate chevron/divider were calibrated to the reference.
Candidate count, ranking, dictionaries, models and single-window expansion are
unchanged; the reference has nine candidates while the user's profile has seven.

187 internal checks passed, including 18 candidate placement/interaction checks.
The 7-candidate AppKit preview is 630 x 58 px with 28 px glyphs. The rebuilt DMG
passed read-only mounting, signing-structure, minimum-OS, library/data-boundary
and offline-engine checks. These checks do not prove real-host caret alignment.

The native installation service installed 0.4.1 and verified deployment/model
load while preserving all settings. The user profile's font was then changed
through the appearance page and saved successfully. A structured comparison
confirms fontSize 18 -> 16 is the only settings change, with pageSize still 7;
deployment reports success=true and modelVerified=true. Both installed app
versions read back as 0.4.1. Actual typing, caret attachment and expansion remain
pending user confirmation. The existing 0.4.0 GitHub preview assets are unchanged.

Evidence: build/native-geometry-{build,tests,package,distribution,install}.log and
build/native-geometry-row.png (ignored local files). Pushed-head CI must be read
back separately; local success is not a remote CI result.

The first geometry CI (40466635055) passed the engine checks but detected a
fractional-metric overlap between the last expanded column and the chevron.
Grid columns now use whole-point boundaries; the same 18 interaction checks and
rebuilt distribution checks pass locally. A new remote run is still required.

## Installable preview and optional components — 0.4.0

The normal QingType app now opens a native welcome page, installs/enables the
bundled input service, and offers independent opt-in Rime Ice and Wanxiang
installation. First launch does not download either. Model selection follows the
saved simplified/traditional schema. Transfers have progress/cancellation and
official SHA-256/size checks; activation still uses configuration recovery and
verified grammar loading. The existing candidate window is retained.

The default build extracts a hash-pinned Squirrel 1.1.2 archive without relying
on a locally installed Squirrel. Legacy optional .gram files are stripped. Both
executables target macOS 14.0, verified in Mach-O headers. The normal app has its
own bundle ID and packages the input service, libraries and base resources.

186 local checks passed: the prior 160, 20 setup/catalog/install rollback/native
cache checks, and six offline factory engine checks. Package inspection verifies
absence of optional models, Ice and personal data, default resources, portable
DMG checksum, actual minimum OS and library paths. The read-only DMG is mounted,
its nested signing structure verified, and its payload passes the factory engine
test. This does not prove Developer ID/Gatekeeper distribution acceptance.

All four component combinations were tested: neither (factory), Ice only, model
only (8 factory/model checks), and Ice plus model (17 Ice engine checks). The model
was downloaded by the native official downloader, SHA-256 checked and executed
by the real engine; its load is visible in plugin output. Transfer cancellation
was also tested. Optional-download tests use temporary/reference data, not new
models activated in the user's existing profile.

A harness using the same native InstallationService upgraded the local input
service to 0.4.0, verified source enablement, deployment and existing model load,
and confirmed all settings values were preserved. This is a backend invocation,
not a successful graphical click-through. New window inspection remains blocked
by a locked Mac; actual keyboard acceptance is deferred as requested.

Local evidence: build/setup-tests.log, distribution-tests.log,
native-install-040.log, factory-wanxiang-test.log, setup-ice-wanxiang-test.log,
wanxiang-download.log and wanxiang-download-cancel.log. The new CI runs bootstrap,
the full suite and DMG packaging/inspection; its result must be checked at the
pushed source revision. No valid local signing identity exists (0 identities),
so Developer ID/notarization branches are prepared but unexecuted. The source at
93bb9b7 passed CI 40377756642 and was published as v0.4.0-preview.1 with the tested
DMG and SHA-256 file. GitHub's uploaded asset digest matches the local DMG digest.
This is a public preview, not clean-Mac GUI/install/uninstall or Apple notarization acceptance.

## Rime Ice integration — 0.3.1 (2026-10-27)

The user confirmed the complete Rime Ice scheme, with QingType's native candidate
window and settings as the priority. Its AppKit/SwiftUI presentation remains in
use; the package's client configuration and themes are excluded.

The official Release downloader validates full.zip size and GitHub's SHA-256
digest, checks ZIP paths/types/bounds, then installs the three schema dependencies,
Chinese/English dictionaries, Lua (including lunar.db), OpenCC and symbol resources.
Package defaults are namespaced rather than replacing existing defaults, phrases,
Xiaohe files or user custom patches. A manifest, upstream license, owned-file
conflict checks, resource backups and activation rollback are included.

160 internal checks passed: the prior 116, one numeric dictionary-name import
regression, 27 package/isolation/rollback/archive checks and 16 real-engine checks.
The latter use the complete official package in a temporary directory: nihao,
configured page size, personal selection and exact commit, English, Lua date and
lunar data, quick phrases, restart, fixed-row deletion and stable learning identity.
The fixed personal-source checks disable learning; Phase 2 behavior remains pending.

A separate 17-check run used the existing local simplified Wanxiang model. The
plugin output confirms its grammar language, .gram load and double-array image,
in addition to candidate functionality. No model or user words are committed.

0.3.1 is installed locally. A command-line harness calling the same native download
and DeploymentService functions successfully installed the official package and
verified the active, unchanged scheme plus actual model load. All 59 installed
resource hashes match. Every pre-existing settings value is unchanged; the old
JSON gained the expected empty personalWords field and rimeIce metadata. The
current selected schema remains Luna simplified; Rime Ice can be selected in the
input settings and applied. Source Rime data is not a writable target.

The new graphical controls compile, but live window inspection was blocked by a
locked Mac. This is not recorded as a successful UI click-through. Actual typing
and candidate-window acceptance is deferred at the user's request. Local evidence
is in ignored build/rime-ice-tests.log, rime-ice-model-test.log,
rime-ice-install-result.json and the deployment logs. CI additionally fetches a
fixed upstream Rime Ice commit; its result must be checked against the pushed head.


## Phase 0 / Phase 1 — 0.3.0 (2026-10-27)

The user's roadmap is in ROADMAP.md; repository guidance and current handoff are
AGENTS.md / PROGRESS.md. BASELINE.md records the starting 0.2.2 toolchain,
verification scope, installation/recovery behavior and remaining release gaps.
`python3 scripts/capture-baseline.py` generates the actual runtime/toolchain and
binary-digest report in ignored build/baseline.json without word-entry contents.

The personal dictionary now has native settings UI for CRUD, weight, search and
sorting. CSV/TSV/TXT import first previews row results, then applies an explicit
conflict policy. Exports and complete inspection reports use native save dialogs.
The new settings field migrates from earlier JSON and generates an owned Rime
personal table, used by the existing full-pinyin and Xiaohe schemas.

The apply lifecycle stops the input service before saving. It snapshots only
managed configuration, deploys, and restores/recompiles the previous configuration
if deployment fails. External edits stop rollback instead of being overwritten;
failed recovery keeps the service stopped and reports the backup location.
Explicit schema compilation is required: an old usable compiled table must not
mask a failed dictionary build.

116 internal checks passed: the original 61 plus 35 personal data/import/export/
transaction checks and 20 actual engine integration checks. The latter exercise
new word selection and exact commit, changed spelling and weights, CSV round-trip,
Xiaohe, restart, deletion, explicit compile failure and recovery. Their fixed-source
CRUD fixture disables the user dictionary so an intentionally learned copy cannot
masquerade as a fixed row. This does not validate Phase 2 learning behavior.

The native page and editor were inspected through accessibility and a screenshot;
empty input produced a validation message and cancelling left the saved data
unchanged. Version 0.3.0 was installed and read back in the About UI; settings.json
was byte-identical before/after installation. The user deferred real-keyboard
acceptance, so user-application entry creation and input remain unverified. Do not mark Phase 1 fully accepted from internal tests alone.

## 0.2.2 Safari input-source selection

User reported that selecting QingType in Safari had no effect. The Safari
keyboard-source cache already contained QingType, so the earlier QQ diagnosis
alone did not explain this failure. Launch logs also recorded two QingType app
copies competing for the same endpoint.

The generated InputMethodConnectionName now uses the full bundle identifier plus
_Connection, matching the connection naming convention documented by the
[vChewing developer's IMK notes](https://github.com/ShikiSuen/ShikiSuen/blob/main/TechNotes/macOS_Input_Method_Development_Guidelines_2026/macOS_Input_Method_Development_Guidelines_2026-ENU.md).
The service refuses a second instance and checks IMKServer creation. The weak
client binding is refreshed on each key event and activation, and lifecycle logs
contain application identifiers rather than typed text. Bundle checks now guard
the connection convention and matching input-method/settings versions.

Build, signature verification and the existing 61 internal checks passed.
After installing 0.2.2, a fresh TIS selection returned OSStatus 0 and selected=true.
That alone did not prove Safari acceptance: the user initially still could not
switch in the already-running Safari process. The user then completely restarted
Safari and explicitly confirmed that switching worked. This confirms recovery in
that session; other browser/application combinations remain separate validation.

## 0.2.1 regression repair

QQ produced two matching crash reports inside the system source-switching HUD:
`TISCopyInputSourceRefForInputSourceID` returned NULL, then the framework called
`CFRelease` on it. The shared keyboard table contained QingType; QQ's private
keyboard table predated installation and did not. This is consistent with the
sandbox input-source cache issue independently documented in
[Qingjian issue 346](https://github.com/qingjian-team/qingjian/issues/346).
No private framework hooks or private TIS calls are shipped in QingType.

The installer now waits for the input service to exit, backs up only the two
named IntlDataCache keyboard tables, refreshes registration even for enabled
modes, and rechecks enabled state from fresh processes. Cache backups and full
local crash reports are excluded from Git. Local installation backed up 183 cache tables with no skips; QingType 0.2.1
registered successfully, remained enabled, and settings.json was byte-identical
before/after installation. Real QQ input remains user validation;
this document does not claim that a successful engine test proves QQ is fixed.

The old IMKCandidates + floating arrow + separate grid implementation below is
superseded. One AppKit panel now owns all candidate controls. Seventeen new UI checks cover
caret placement in a negative-origin display, screen-edge flipping, separate
arrow hit regions, same-window expansion, selection/scroll persistence, Escape,
and absolute-index numeric and Space selection. The cache helper tests preserve
unrelated files, backup bytes, symlinks, existing backups and root boundaries.

## Passed

- InputMethodKit app and SwiftUI settings app compile, install and pass local
  ad hoc signature verification. Yams is pinned through Package.resolved.
- Nine settings safety checks: Unicode persistence, invalid and duplicate phrase
  rejection, no partial invalid save, manual configuration protection, recovery
  backup, corrupt JSON handling and a dedicated user directory.
- Thirteen content/migration checks: recursive import_tables, owned file copies,
  flattened import list, disabling dictionaries, intact original files,
  circular/missing/traversal dependency rejection, truncated model rejection,
  preservation of old preferences, and three model-log verification checks.
- Nineteen Rime checks in an isolated temporary directory: full pinyin candidates,
  paging, Escape, Backspace, commit selection and exact text, custom phrases,
  Xiaohe candidates, and imported dictionary entries available in both input modes.
- Candidate row, arrow and grid now share one nonactivating AppKit panel; the
  inherited Squirrel candidate panel remains a selectable fallback.
- User confirmed with a real keyboard: selecting QingType, typing `nihao`, seeing
  candidates, and pressing Space inserts `你好`. The test field was also read back
  as `你好` through accessibility.
- TISCopyCurrentKeyboardInputSource reported QingType.Hans after switching via
  the system input-source shortcut. The previous command-line selection failure
  is no longer considered a blocker for using the input source.
- Imported the user's existing cs408 dictionary into QingType: 641 entries.
- Imported a copy of the existing Simplified Chinese Wanxiang model:
  398,497,836 bytes; SHA-256
  `9eedac1d836f3fdafb61b162035c8937253aedc106be40b2b957d9ab64e9ed89`.
- Applied settings from the installed 0.2 settings app. Deployment returned
  `success=true` and `modelVerified=true`. The UI visibly reports that dictionaries
  were compiled and the language model was loaded by the engine.
- Model evidence includes the selected grammar name, opening the imported .gram,
  and a successful gram_db double-array image load. Both regular Rime log files
  and plugin stderr are checked. Spelling-prism success cannot stand in for a
  grammar-model success. Plugin output is saved with each deployment.

## Current limits

The AppKit candidate renderer is not assumed to be pixel-identical to
Apple's built-in Chinese input method. Its detailed interactions, expanded
candidates, cross-application caret tracking, multiple displays, dark mode and
long sessions still need systematic comparison.

Automated UI key events did not reliably trigger composition in either Apple
pinyin or QingType. Real-keyboard confirmation is therefore the input acceptance
criterion; the automated engine tests alone do not prove UI compatibility.

No measured improvement in sentence accuracy is claimed from model loading.
The default base dictionary is Luna Pinyin; the complete Wanxiang schema/package
is separate from importing a .gram model. Current imports accept Rime dictionary
data and dependencies, not arbitrary schema/Lua packages or .scel dictionaries.

Standalone `--preview-system` is only a developer experiment without an active
input session. Offscreen NSView cache captures of that system window are not a
reliable representation of its on-screen appearance. The product directs users
to the real input test field instead of displaying a simulated native preview.

## Evidence and rerun

```sh
./scripts/build-dev.sh
./scripts/test.sh
./scripts/install-dev.sh
```

Use the installed settings app's Save and Apply action for exclusive deployment.
The direct --deploy-user-data command refuses to run while the input method is
active, protecting the user's database lock.

Evidence: build.log, build/test-results.log, build/install-results.log,
build/verified-deployment.json, and the deployment-logs directory under the
QingType user directory. Developer ID signing, notarization, public updates,
independent runtime builds and a broader compatibility matrix remain future work.

## Earlier IMKCandidates experiment (superseded in 0.2.1)

The first supplied screenshot is QingType (Rime candidates such as 妳好/逆号);
second is Apple's pinyin. The user explicitly limited this change to appearance.
Vocabulary, model, sorting and input preferences were preserved byte-for-byte
through installation, verified against the pre-update settings SHA-256.

Changes: selection keys now explicitly use an ASCII-capable keyboard layout,
with NSNumber key codes applied after the candidate data. The native panel gets
up to 64 candidates beginning at the current engine page, instead of only one
page, allowing its public paging controls to know more data is available.
Native selection/highlight callbacks map back to absolute Rime indices.

Five added engine checks passed: data extends beyond the first row; reading it
does not change first-page order or page state; later-page highlighting works;
numeric selection on that page commits; the committed candidate has the expected
absolute index. The suite now passes 9 safety + 13 content + 19 engine checks,
plus bundle identity and signature checks.

Actual numbering and paging-control appearance are awaiting real-keyboard visual
confirmation. Apple's private expanded-candidate UI is not assumed to be exposed
by the public IMKCandidates paging component.

## Expand/collapse and background revision

The user confirmed numbering and the right-side paging entry appeared after the
first appearance patch, then clarified that the desired arrow must expand the
window into a grid. The user explicitly excluded the bottom toolbar and asked
for the official reference's background color. Dictionary/ranking changes remain
out of scope.

Implemented a nonactivating AppKit grid with up to six columns, a fixed first row
of small candidate numbers, aligned word origins in all rows, subtle horizontal
separators and rounded selection highlights. The background is an adaptive light
sRGB #F2F2F2 / dark charcoal surface, avoiding the old popover material's darker
vibrancy tint. No bottom toolbar or footer remains. A top-right chevron and Escape
collapse the window. Arrow keys and first-row number keys are routed to the
stored absolute candidate indices. Selection and composition retain the text
client's focus.

The expand button follows the native candidate frame, and its level is matched
above the native window. Expanded placement follows whether the collapsed window
was above or below the caret and flips when screen space requires it.

Build and the existing suite passed after these changes. A live AppKit preview
was inspected through accessibility and a screenshot. Clicking the second-row
first candidate produced global index 6 in the preview callback. The collapse
callback also completed. The rendered preview is build/expanded-candidate-preview.png.

The user explicitly took responsibility for further real-input validation;
expanded interaction in the installed IME remains for the user to check.
