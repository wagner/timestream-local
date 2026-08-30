---
name: release
description: Cut a release of timestream-local — pick the version from the Unreleased changelog entries, bump the VERSION constant, close the changelog section, verify, then commit, push and tag. Use when asked to release, cut a version, ship a version, or publish a new image tag.
---

# Releasing timestream-local

Tagging is what publishes. Pushing a `v*` tag runs `.github/workflows/release.yml`,
which runs the suite, refuses to continue if the tag and the `VERSION` constant
disagree, builds `linux/amd64` + `linux/arm64`, pushes to ghcr.io, and smoke tests
what it pushed.

Run the git commands yourself — committing, pushing and tagging a release are
authorised in this repo. Releasing commits to `main` rather than a branch; that is
deliberate, because the tag has to sit on the released commit.

Two things are not negotiable, because pushing a tag publishes a public image:

- **Verify before you push anything.** If step 4 fails, stop and report. Never
  tag past a failure.
- **Say what you are about to publish before you publish it** — the version, the
  one-line summary, and which floating tags will move. Not to ask permission, but
  so the action is legible before it is irreversible. A published tag can be
  replaced, but anyone who pulled it in between already has it.

## Steps

### 1. Read what is unreleased

Open `CHANGELOG.md` and read the `## [Unreleased]` section. If it is empty, stop
and say so — there is nothing to release, and cutting an empty version is worse
than not cutting one.

### 2. Choose the version

Derive it from the entries rather than asking, unless they are genuinely
ambiguous:

| Unreleased contains | Bump |
| --- | --- |
| Anything under `### Removed`, or a documented breaking change | major |
| Anything under `### Added` | minor |
| Only `### Fixed`, `### Changed`, `### Security`, docs, or internals | patch |

State which you chose and why in one line. If a change is behavioural but not
obviously breaking, say so and let the user decide.

### 3. Update the two places the version lives

- `lib/timestream_local.rb` — the `VERSION` constant. This is the source of truth
  and the workflow checks the tag against it.
- `CHANGELOG.md` — rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`, add a
  fresh empty `## [Unreleased]` above it, and update the link definitions at the
  bottom.

Also update `README.md` if it names a specific image tag in the pull or compose
examples.

### 4. Verify before handing over

```sh
bundle exec rake test
ruby -e 'print File.read("lib/timestream_local.rb")[/VERSION = "([^"]+)"/, 1]'
```

The second is the exact command the workflow runs — it deliberately does not load
the library, so it cannot fail for reasons unrelated to the version. Confirm it
prints the version you chose.

If the release touches the image (anything but docs), also build it and run the
suite against the container, because a green in-process suite does not prove the
image works:

```sh
docker build -t timestream-local:rc .
CID=$(docker run -d --rm -p 18080:8080 \
  -e TIMESTREAM_LOCAL_ADVERTISED_ENDPOINT=http://localhost:18080 timestream-local:rc)
TIMESTREAM_LOCAL_ENDPOINT=http://localhost:18080 bundle exec rake test
docker stop "$CID"; docker rmi timestream-local:rc
```

### 5. Publish

State the version, the commit summary, and which floating tags will move. Then:

```sh
git add -A && git commit -m "X.Y.Z: <one line summarising the release>"
git push origin main
git tag vX.Y.Z && git push origin vX.Y.Z
```

The last line is what publishes. A release moves `X.Y` and `X` onto the new
version; anyone pinned to a full version is unaffected, anyone floating is not.
Say that every time — a consumer mid-debug will not otherwise consider that the
image changed underneath them.

The workflow takes ~5 minutes; the arm64 half compiles native gems under QEMU.

### 6. After the tag is pushed

Confirm the artifact rather than trusting a green run:

```sh
gh run list --limit 1
docker manifest inspect ghcr.io/wagner/timestream-local:X.Y.Z   # both platforms?
docker pull ghcr.io/wagner/timestream-local:X.Y.Z
```

Then run the suite against the pulled image. A published image that builds but
does not boot is the failure this catches, and a green workflow does not prove it
— the smoke test only checks that `/health` answers.

Report the outcome either way. If the workflow failed, say so plainly and do not
re-tag until the cause is understood: the first release here failed because the
version check loaded the library without bundler, and re-tagging would only have
reproduced it.

## Keeping the changelog honest

Between releases, add an entry under `## [Unreleased]` as part of the change that
warrants it — not in a sweep before releasing, where it becomes a reconstruction
from memory.

An entry earns its place if it changes what a user sees or does. Say what changed
and, for a fix, what the wrong behaviour was: several bugs here returned plausible
wrong answers rather than errors, and "fixed a bug in the rewriter" would not have
helped anyone recognise they had hit one. Internal refactors with no visible
effect do not need an entry.
