# DiskScope

**Understand where your Mac's disk space actually went — in plain English.**

macOS tells you how much space is gone. It rarely tells you why. Finder's
storage view has a category literally called "System Data" that can hold
hundreds of gigabytes, is not a folder, and cannot be inspected with `du`.
DiskScope exists to replace that shrug with an actual explanation.

```
$ diskscope explain ~/Library

  App caches                    12.4 GB   Scratch data that apps rebuild when
                                          launched. Growing without bound is
                                          normal; growing forever is not.

  Developer caches               8.1 GB   Build tool caches: Xcode DerivedData,
                                          SwiftPM artifacts. Deleting costs a
                                          slow rebuild, not your source code.

  Time Machine snapshots         6.2 GB   Local APFS snapshots. Not a folder —
                                          which is why no directory walk finds
                                          them, and why they read as mystery
                                          "System Data".
```

> The block above is the intended output, not a transcript. `explain` is the
> first command being built; see the status table for what runs today. The
> numbers are illustrative.

## Status

**Early. The analysis engine is solid and tested; the CLI is not written yet.**

| Area | State |
| --- | --- |
| Filesystem scanner | Done, tested |
| Category taxonomy and explanations | Done, tested |
| Classification rules | Done, tested |
| Model grounding and validation | Done, tested |
| `diskscope` CLI | **Not started** |
| Duplicate detection | Not started |
| App inventory and leftovers | Not started |
| Cleanup and deletion | Not started |

Everything committed so far is the engine that a CLI would sit on top of. It is
covered by 58 tests, including checks that pin the behaviour that is easy to
get quietly wrong — physical size versus logical size, hard links counted once,
symbolic links never followed, and unreadable directories reported rather than
silently counted as empty.

## Why a command line tool

Three reasons, in order of importance.

**Full Disk Access is easier to trust in a terminal.** A disk analyser that
wants to read `~/Library/Mail` has to be granted Full Disk Access by hand. In a
GUI that means "trust this modal dialog". From a CLI it means running
`diskscope doctor`, which prints the exact paths that came back `EACCES` and
why, so you can verify the grant worked rather than assume it.

**You can check the numbers yourself.** Every figure DiskScope prints comes from
`st_blocks` via the filesystem. Nothing is estimated, and for the AI features
you can dump the exact payload with `--dry-run` before letting anything be sent.

**It builds without Xcode.** The package has no third-party dependencies and no
`.xcodeproj`. `swift build` works from a Command Line Tools install alone, which
is a deliberately unusual choice for a Mac app and is discussed below.

## Building

Requires Swift 6 and macOS 14 or later. Xcode is not required.

```sh
git clone https://github.com/aryanmiriyala/DiskScope
cd DiskScope
swift build -c release
swift run DiskScopeTests        # 58 tests, no external test framework needed
```

## Architecture

```
Sources/
  DiskScopeCore/     Pure, offline, zero dependencies. Knows nothing about
                     the network, the Keychain, or any UI.
    Scanning/        POSIX filesystem walk
    Analysis/        Path → category rules
    Model/           The taxonomy and its explanations
    AI/              Contracts for grounding model output in measured data

  DiskScopeAI/       Language model backends and Keychain access.
  DiskScopeApp/      The command line tool.
```

`DiskScopeCore` deliberately depends on nothing but Foundation. That is not
minimalism for its own sake: this code walks a user's home directory and is
asked to delete things, so every line of third-party code that runs alongside it
is a line that has to be trusted with access to all of it.

### Tests without XCTest

There is no `Tests/` target in the usual sense, and no XCTest. Neither XCTest
nor swift-testing ships with the Command Line Tools, and requiring a ~15 GB
Xcode install to verify a ~5,000 line project is a bad trade. `DiskScopeTests` is
an ordinary executable target with a ~150 line harness that mirrors the
swift-testing API (`expect`, `require`, throwing async bodies), so migrating to
it later is an import swap rather than a rewrite.

Run a subset by substring:

```sh
swift run DiskScopeTests scanner
swift run DiskScopeTests validator
```

### Things that are easy to get wrong

These are the decisions the tests exist to protect.

**Physical size, not logical.** `st_blocks * 512` is what a file actually costs
on the volume. A 40 KB file occupies 8 KB of blocks, so a directory of tens of
thousands of small files can be far larger on disk than the sum of its file
sizes. Reporting only logical size is why some apparently empty directories turn
out to be hundreds of megabytes.

**Hard links are counted once.** Xcode and Photos both create them. Counting per
path inflates totals badly.

**Symbolic links are never followed.** Following them escapes the requested
roots or loops forever. They are recorded as metadata and not traversed.

**Unreadable is not the same as empty.** Every `EACCES` becomes a record with a
reason. An analyser that reports `0 bytes` for a directory it was not allowed to
open looks identical to one that found a genuinely empty directory, and that
difference is exactly the kind of thing that makes people stop trusting a tool.

## AI features

DiskScope can explain directories the rule table could not classify, and answer
questions about a scan in plain language. It will also never tell you a size
twice.

**The rule: a language model may label, group, rank and explain. It may never
supply a number, a path, or a deletion target.**

This is enforced structurally rather than by convention:

- `QueryAnswer` has no size field. There is nowhere for a model to put a figure.
- Every path a model cites is resolved against the scan. A path that does not
  exist on disk is discarded, and the UI says so.
- All arithmetic is ours, summed from measured `st_blocks` values.

The reasoning is specific. This project exists because macOS showed someone an
unexplained number they did not trust. Shipping a tool whose language model
asserts "that's probably about 12 GB of caches" without having measured
anything would rebuild the exact failure being escaped, with better typography.
A model that picks which *measured* bucket to describe is useful. One that
estimates is worse than no feature at all.

### Privacy

Backends are ordered local-first:

- **On-device** (Apple's model, macOS 26 on Apple Silicon) — nothing leaves.
- **Cloud** (BYOK) — the user supplies their own key, stored in the Keychain with
  `kSecAttrAccessibleWhenUnlocked`.

Paths leak more than they look: a username, project names, client names, and
occasionally the name of a document nobody wants in a third-party log. Cloud
access is opt-in, and the consent step shows the literal payload rather than a
checkbox.

## Contributing

Small, focused commits are preferred, and a pull request that fixes one thing is
much easier to review than one that fixes five. Run `swift run DiskScopeTests`
before pushing.

Two areas especially welcome:

- **Classification rules.** The table in `LibraryClassifier` is ordered, and a
  new rule placed in the wrong position will silently steal paths from a more
  specific rule above it. Add a test for anything you add.
- **Explanations.** A category is only as useful as its prose. If something on
  your Mac is being explained badly or falling into "Other", that is a bug.

## License

MIT. See [LICENSE](LICENSE).

The zero-dependency property is worth preserving deliberately. If a change
proposes adding a package, it should have to argue why that code is now trusted
with access to a user's home directory.
