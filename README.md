<div align="center">

# DiskScope

**Understand where your Mac's disk space actually went.**

[![CI](https://github.com/aryanmiriyala/DiskScope/actions/workflows/ci.yml/badge.svg)](https://github.com/aryanmiriyala/DiskScope/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macos-14%2B-4479a1?style=flat-square&logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/swift-6.0-F05138?style=flat-square&logo=swift&logoColor=white)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square)](LICENSE)
[![Deps](https://img.shields.io/badge/dependencies-0-success?style=flat-square)](#why-there-are-no-dependencies)

macOS tells you *how much* space is gone. It rarely tells you *why*. Finder has a
category called "System Data" that can hold hundreds of gigabytes, is not a
folder, and cannot be inspected with `du`.

DiskScope replaces that shrug with an actual explanation.

[Why it's built this way](#why-a-terminal-tool) · [Design rules](#design-rules)
· [AI features](#ai-features) · [Limitations](#limitations) · [Contributing](#contributing)

</div>

## Demo

Real output, scanning a 32 GB `~/Library`:

```
$ diskscope explain ~/Library

Scanning /Users/you/Library

What is using the space
───────────────────────
      13.5 GB  App container data        Sandboxed app data, one container per
              app under ~/Library/Containers. Deleting
              a container resets that app to a fresh
              install.

       7.5 GB  Application support fil…  Where apps keep the things they consider
              durable: settings, databases, plugins,
              project files. This is app state, not
              scratch space.

       4.8 GB  Messages                  Attachments and database files for the
              Messages app — images, videos, and the
              message history itself. This is your
              conversation history, not a cache.

       3.1 GB  App caches                Scratch data that apps rebuild when
              launched — thumbnails, decoded images,
              partially downloaded files. Growing
              without bound is normal; growing forever
              is the problem.
              Written by apps under ~/Library/Caches and by macOS under /Library/Caches.
```

Three things to notice.

**Every size is measured, never estimated.** It comes from `st_blocks` — the
blocks the file actually occupies on the volume. See [design rules](#design-rules).

**The column of prose is the product.** The pie chart is just a way of deciding
which explanation to read. A tool that says "13.5 GB" without saying *what* is
the thing you have to trust.

**"Messages" is not offered as cleanup.** It is your conversation history. The
tool knows the difference between scratch space and your actual data.

## Status

Early, and honest about it. The analysis engine is tested and validated against
`du`; several commands are not written yet.

| Area | State |
| --- | --- |
| Filesystem scanner | Done — 72 tests |
| Category taxonomy and explanations | Done |
| Classification rules | Done |
| Deletion safety model | Done |
| Model grounding and validation | Done |
| `explain`, `doctor`, `categories` | Done |
| Byte totals validated against `du` | Verified |
| Duplicate detection | Not started |
| App inventory and leftovers | Not started |
| `clean` (deletion) | Not started — **nothing is deleted today** |
| `ask` (AI query) | Not started |

## Install

Build from source. Requires Swift 6 and macOS 14+; **Xcode is not required**, and
there are no dependencies to resolve.

```sh
git clone https://github.com/aryanmiriyala/DiskScope
cd DiskScope
swift build -c release
cp "$(swift build -c release --show-bin-path)/DiskScope" /usr/local/bin
```

Run the tests:

```sh
swift run DiskScopeTests              # all 72
swift run DiskScopeTests scanner      # substring filter
```

## Usage

```sh
diskscope explain ~/Library           # breakdown with explanations
diskscope explain . --limit 5         # top 5 only
diskscope explain ~/Library --json -  # machine-readable
diskscope doctor                      # check Full Disk Access
diskscope categories                  # every category and what it means
diskscope help explain
```

| Flag | Effect |
| --- | --- |
| `--limit N` | Show only the N largest categories |
| `--json FILE` | Write a report as JSON (`-` for stdout) |
| `--no-color` | Disable ANSI colour. Also honours `NO_COLOR` |

## Why a terminal tool

**Full Disk Access is easier to trust here.** A disk analyser needs to read
`~/Library/Mail`, which macOS hides until you grant access by hand. A GUI asks
you to trust a modal dialog. `diskscope doctor` prints each protected path, what
happened, and what to do about it — so you verify the grant instead of assuming
it.

**You can check the numbers.** Disk totals are validated against `du`. Nothing
is modelled or guessed, and `ask --dry-run` shows the literal payload before
anything leaves your machine.

**It builds without Xcode.** This is an unusual choice for a Mac project and a
deliberate one: it means a contributor can verify ~5,000 lines without a ~15 GB
install.

## Design rules

These are the decisions the tests exist to protect. Each one is a way the tool
could look correct while being wrong.

**Physical size, not logical.** `st_blocks * 512` is what a file actually costs
on the volume. A 40 KB file occupies 8 KB of blocks, so a directory of tens of
thousands of small files can be far larger on disk than the sum of its file
sizes. Reporting only logical size is why some apparently empty directories turn
out to be hundreds of megabytes.

**Hard links are counted once.** Xcode and Photos both create them. Counting per
path inflates totals badly.

**Symbolic links are never followed.** Following them escapes the requested roots
or loops forever. They are recorded as metadata and not traversed.

**Unreadable is not empty.** Every `EACCES` becomes a record with a reason. An
analyser that reports `0 bytes` for a directory it was not allowed to open is
indistinguishable from one that found a genuinely empty directory — and that
indistinguishability is exactly what makes people stop trusting a tool.

**Each file is counted once.** A directory record carries its *subtree* total, so
summing totals across directories counts every file once per ancestor. On a real
home directory that inflated the file count by roughly seven times while every
other number stayed plausible. `ownFileCount` exists to make the correct sum
possible, and a test pins it.

**Data loss is never offered for deletion.** `RiskLevel.destructive` means "this
is your data". It sits *below* `.informational` in the raw enum ordering, and an
earlier version derived "can we delete this?" from that ordering — which offered
exactly the data the risk model exists to protect. It is now an explicit switch,
because *how risky deletion is* and *whether to offer it* are different questions.

**Unidentified data is never auto-deleted.** Anything DiskScope cannot classify
is reported as `Other` with the same prominence as a recognised category, and is
never a cleanup candidate. If it were safe to delete, we would know what it was.

## AI features

DiskScope can explain directories the rule table could not classify, and answer
questions about a scan. It will also never tell you a size twice.

> **A language model may label, group, rank and explain. It may never supply a
> number, a path, or a deletion target.**

This is enforced by the type system, not by convention:

- `QueryAnswer` has **no size field**. There is nowhere for a model to put a figure.
- Every path a model cites is resolved against the scan. A path that does not
  exist on disk is discarded, and the UI reports the discard.
- Overlapping groups are de-duplicated, so group sizes cannot be double counted.
- All arithmetic is ours, summed from measured `st_blocks`.

The reason is specific. This project exists because macOS showed someone an
unexplained number they did not trust. A tool whose language model asserts
"that's probably about 12 GB of caches" without having measured anything would
rebuild the exact failure being escaped, with better typography.

### Privacy

Local-first, cloud opt-in:

- **On-device** — Apple's model, macOS 26 on Apple Silicon. Nothing leaves.
- **Cloud (BYOK)** — your own key, stored in the Keychain with
  `kSecAttrAccessibleWhenUnlocked`, never in preferences or a plist.

Paths leak more than they look: a username, project names, client names, and
occasionally the name of a document nobody wants in a third-party log. Cloud
access is opt-in and the consent step shows the literal payload rather than a
checkbox.

## Why there are no dependencies

There are none, and adding one has to argue why that code is now trusted with
access to a user's home directory. That is also why the argument parser is
hand-rolled and the SHA-256 is in-tree.

Tests use a ~150-line in-package harness instead of XCTest or swift-testing:
neither ships with the Command Line Tools, and requiring Xcode to run
`swift test` would defeat the point. The harness mirrors swift-testing's API, so
migrating later is an import swap rather than a rewrite.

## Limitations

Known, and not hidden:

- **Nothing is deleted yet.** There is no `clean` command. This is deliberate —
  the safety model had to exist before the deletion path did.
- **Local snapshots are counted but not sized.** Time Machine local snapshots
  are APFS snapshots, not files, so no directory walk can find them. DiskScope
  reports the *count* and points at `tmutil`; it does not estimate their size.
  This is a real gap in explaining "System Data".
- **The system volume is reported, not analysed.** `/System/Volumes/Data` is
  probed for capacity but not walked in detail.
- **On-device AI needs macOS 26 on Apple Silicon.** On anything older, AI
  requires a BYOK cloud key.
- **Slower than `du`.** On a 2.6 M file home directory DiskScope takes ~100 s
  where `du` takes ~20 s, because DiskScope also classifies, explains and
  hard-links-deduplicates. It does not yet use batched `getattrlistbulk`.
- **No interactive TUI.** Output is a report, not a drill-down explorer.

## Alternatives

Well-made tools, different goals:

- [**dust**](https://github.com/bootandy/dust), [**dua**](https://github.com/Byron/dua-cli),
  [**gdu**](https://github.com/dundee/gdu), [**ncdu**](https://dev.yorhel.nl/ncdu) —
  faster, interactive, and better at *navigating* a tree. They report sizes.
- `du -d 1 -h | sort -h` — the same information with less code.

**DiskScope's difference is the explanation and the safety model**, not the
sizes. If you want a fast interactive explorer, use dust. If you want to know
what the 13 GB of `Containers` actually is and whether any of it is safe to
remove, use this.

**Why you might not want DiskScope:** if you are comfortable reading `du -a`
output and classifying folders yourself, this is slower and does less. It is a
teaching tool with a deletion guardrail, not a performance tool.

## Contributing

Small focused commits please — a pull request that fixes one thing is much
easier to review than one that fixes five. Run `swift run DiskScopeTests` first.

Two areas especially welcome:

- **Classification rules.** The table in `LibraryClassifier` is ordered and
  first-match-wins. A rule placed in the wrong position silently steals paths
  from a more specific rule above it. Please add a test.
- **Explanations.** A category is only as useful as its prose. If something on
  your Mac is explained badly or falling into `Other`, that is a bug worth
  reporting with the path.

## License

MIT — see [LICENSE](LICENSE).

Copyright © 2026 Aryan Miriyala.
