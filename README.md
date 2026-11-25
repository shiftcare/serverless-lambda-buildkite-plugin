# serverless-lambda-pipeline

Shared Buildkite pipeline for the `serverless-service-*` Lambda repos. A
service repo's pipeline is a single bootstrap step. That step clones a pinned
tag of this repo and runs `generate_pipeline.sh`, which builds the real
pipeline from `templates/` and uploads it.

Current steps:

- **package**: Serverless v2 `package` with no AWS credentials available to
  Serverless (see [limits](#how-packaging-withholds-aws-credentials)).
  Uploads one build artifact, `dist/<SERVICE>.zip`.

Publish and deploy steps come in follow-up releases. Their extension points
are marked in `scripts/serverless/generate.sh`.

> **This repo is public.** Never commit account IDs (the all-zeros placeholder
> `000000000000` is the only exception), ARNs, bucket or function names, or
> credentials. CI runs `scripts/ci/check-leaks.sh`, which catches
> account-ID-shaped numbers, AWS ARN prefixes and AWS access-key shapes only;
> bucket and function names are left to review.

## Service repo setup

`.buildkite/pipeline.yml` in the service repo:

```yaml
steps:
  - label: ":pipeline: Generate pipeline"
    agents:
      queue: "tiny"
    env:
      SERVICE: "example-service"
    command: |
      rm -rf .buildkite-shared
      git init -q .buildkite-shared
      git -C .buildkite-shared fetch -q --depth 1 https://github.com/shiftcare/serverless-lambda-pipeline.git refs/tags/v1.0.0
      git -C .buildkite-shared checkout -q FETCH_HEAD
      .buildkite-shared/generate_pipeline.sh
```

Pin a release tag literally, by its full `refs/tags/` name. Do not use
`git clone --branch <tag>`: when a branch with the same name exists, clone
checks out the branch, which the tag ruleset does not protect. Buildkite
interpolates the service repo's own `pipeline.yml`, so any `$VAR` added to that
snippet must be written `$$VAR`.

### Configuration

Set these in the bootstrap step's `env`:

| Variable | Default | Meaning |
|---|---|---|
| `SERVICE` | required | Service name, `^[a-z0-9][a-z0-9-]*$`. Also names the zip: `dist/<SERVICE>.zip`. |
| `PACKAGE_STAGE` | `dev` | Value for `serverless package --stage`. |
| `PACKAGE_REGION` | empty | Value for `serverless package --region`. Required when `serverless.yml` has no `provider.region`: `AWS_REGION` is stripped while packaging, and Serverless v2 then resolves `${aws:region}` to `us-east-1`. |
| `PACKAGE_QUEUE` | `tiny` | Agent queue for the package step. |
| `PACKAGE_AWS_ACCOUNT_ID` | `000000000000` | Exported as `AWS_ACCOUNT_ID` while packaging. |
| `PACKAGE_ENV_PASSTHROUGH` | empty | Space- or comma-separated names of other bootstrap-step variables to copy into the package step's `env`. Each must be set, match `^[A-Z][A-Z0-9_]*$`, have a single-line value, and not be reserved (`AWS_*`, `AMAZON_*`, `BUILDKITE*`, `BK_*`, `PACKAGE_*`, `PIPELINE_*`, `LD_*`, `DYLD_*`, `SERVICE`, `SECRETS_PROVIDER_MODE`, `PATH`, `HOME`, `SHELL`, `IFS`, `ENV`, `BASH_ENV`, `NODE_OPTIONS`, `TMPDIR`, `TMP`, `TEMP`, `NPM_CONFIG_*`, `GLOBIGNORE`, `BASHOPTS`, `SHELLOPTS`, `CDPATH`). **Never list a secret**: values are written into the generated pipeline YAML and are visible in the Buildkite UI. |

Local and test switches:

| Variable | Effect |
|---|---|
| `PIPELINE_DRY_RUN=1` | `generate_pipeline.sh` prints the pipeline YAML and uploads nothing. |
| `PACKAGE_SKIP_UPLOAD=1` | `package.sh` builds `dist/<SERVICE>.zip`, prints its path and skips the artifact upload. |

### Service contract

Serverless has no AWS credentials while packaging, so any AWS read during
variable resolution fails and each service must build without one. Two changes
are needed per service before migrating:

1. `serverless.yml`: `provider.role` (and anything else that needs the account
   ID) uses `${env:AWS_ACCOUNT_ID, aws:accountId}`.
2. `secretsprovider.js`: when `SECRETS_PROVIDER_MODE=placeholder`, return
   placeholder values and make no AWS calls.

Packaging also refuses to start when the service root holds any `.env` or
`.env.*` file, when `serverless.yml` sets `custom.dotenv.path` or
`custom.dotenv.basePath`, or when it cannot check those options: `custom` or
`custom.dotenv` is not a plain map (for example `${file(...)}`), the file uses
any YAML anchor, alias or merge key, in keys as well as values (parsers
resolve these differently), or
the config is not `serverless.yml`/`serverless.yaml` (see step
3 below). No service commits such a file today.

Buildkite does not pass the bootstrap step's `env` on to the steps it uploads.
If `serverless.yml` reads other `${env:...}` values at package time, set them
in the bootstrap step's `env` and list their names in
`PACKAGE_ENV_PASSTHROUGH`. Only non-secret values: they appear in the
generated pipeline YAML, which anyone with access to the build can read in the
Buildkite UI.

## How packaging withholds AWS credentials

`scripts/serverless/package.sh` runs in the service checkout. It refuses to
start when its scratch dir or its own scripts resolve inside that checkout
(for example, `TMPDIR` pointing there), since Serverless would package them
into the zip. Then it:

1. Unsets every `AWS_*` and `AMAZON_*` environment variable (AWS SDK v2 still
   reads the legacy `AMAZON_*` credential names) and sets
   `AWS_EC2_METADATA_DISABLED=true`, which tells the AWS SDKs not to use the
   instance metadata service (IMDS). It runs Serverless with an empty scratch
   `HOME`, so no `~/.aws` files exist for it. The SDKs Serverless uses
   therefore have no credential source. Then it exports `AWS_ACCOUNT_ID` (the
   placeholder) and `SECRETS_PROVIDER_MODE=placeholder`.
2. Deletes a previous `dist/<SERVICE>.zip` (only that file), so Serverless
   cannot package an old artifact into the new one.
3. Runs `npm ci --include=dev` (Serverless is a dev dependency, and a
   passed-through `NODE_ENV=production` would otherwise omit it), then the
   lockfile-pinned, service-local Serverless at
   `node_modules/.bin/serverless`. A global install is never used: the build
   fails if `npm ci` installed no local Serverless, and unless it is major
   version 2. After `npm ci` and before Serverless first runs, it refuses to
   continue if any `.env` or `.env.*` file exists in the service root, or if
   `serverless.yml` sets `custom.dotenv.path` or `custom.dotenv.basePath`
   (or hides them, as in the service contract above).
   Two loaders read these files into Serverless's own environment, which
   could hand it AWS credentials: the core loader (`useDotenv: true`) reads
   `.env.<stage>` or `.env`, and `serverless-dotenv-plugin` reads
   `.env.<NODE_ENV, else --env, in later versions --stage, else development>`
   or `.env` and loads every variable,
   whatever its `include` list says. The refusal applies whatever
   `useDotenv` says.
4. Expects exactly one `.serverless/*.zip`, and requires it to be the service
   package Serverless records as `package.artifact` in
   `.serverless/serverless-state.json` under the name Serverless gives the
   service package it builds, `<service>.zip`. It also refuses when the state
   shows layers, `package.individually`, or a function-level
   `package.individually` or `package.artifact`: those can make or substitute
   a zip under any name. Serverless empties `.serverless/` at package start,
   and a prebuilt service `package.artifact` leaves no zip there. The only
   other zip Serverless writes is its own `custom-resources.zip` (for REST API
   logs, EventBridge without CloudFormation, and `existing` S3 or Cognito
   events), which the one-zip rule refuses; none of the current services uses
   those. Layers are
   unsupported anyway: Serverless v2 calls AWS when packaging a service with
   layers (even a prebuilt one), which fails without credentials.
5. Refuses the zip if it contains `.serverless/`, `.env` (a file, or anything
   under a `.env/` directory), `.env.*`,
   `cloudformation-template-*.json`, `serverless-state.json` or
   `dist/<SERVICE>.zip`. If that scan itself fails, packaging stops rather
   than shipping an unscanned zip.
6. Copies the zip to `dist/<SERVICE>.zip` and adds `ci.build.info.txt` at its
   root. That file records the build number, commit, branch, Node and
   Serverless versions, and the UTC build time.
7. Uploads only `dist/<SERVICE>.zip` as a build artifact.

No Docker and no Docker Hub are involved. Agents need Node 22 with npm on
`PATH`, plus `zip`, `unzip` and `yq` v4.40.1 or later (the generator and the
package step both use it).

**Limits.** This removes credentials from the SDKs; it is not a sandbox.
`AWS_EC2_METADATA_DISABLED` does not block the network path to IMDS, so code
that runs during packaging (npm lifecycle scripts in `npm ci`, Serverless
plugins, JS variable files) can still fetch the agent's instance-profile
credentials directly. `npm ci` also runs with the real `HOME`, for registry
auth and cache. Real isolation needs the package queue's agents to have no
useful instance profile, or IMDS blocked to build processes. That is agent
infrastructure, outside this repo.

### How the generated pipeline runs

- The bootstrap step uploads `scripts/**/*.sh` as build artifacts under
  `serverless-lambda-pipeline/`, staged in a temp dir and never in the service
  checkout. Later steps download them into their own temp dir, so they run the
  same script version as the generator.
- The pipeline is uploaded with
  `buildkite-agent pipeline upload --no-interpolation`. Template commands are
  plain bash (`$VAR`, not `$$VAR`). Substituted values reach the agent verbatim.
- Templates use `@@KEY@@` placeholders inside quoted YAML strings. They are
  replaced on the parsed document, literally, so a value cannot add keys or
  steps. Templates pass values to commands through `env:` and never inline
  them into `command:`.

## Checking a zip against the CircleCI build

Compare a Buildkite zip with the artifact CircleCI currently produces:

```bash
unzip -Z1 circleci-build.zip > reference.txt
scripts/serverless/check-zip-contents.sh --raw dist/example-service.zip reference.txt
```

The check ignores directory entries and `ci.build.info.txt` on both sides.
`--raw` takes the reference as an `unzip -Z1` listing, verbatim. Without it,
the reference is an annotated list: blank lines, `#` comments and carriage
returns are ignored, so a real path starting with `#` would be dropped. A
`--raw` reference saved with CRLF line endings will not match: keep it as
produced by `unzip -Z1`. `--raw` must be the first argument. It
exits 0 on a match, 1 on a difference (with a unified diff: `-` reference,
`+` zip) and 2 on a usage or read error.

## Running locally

```bash
# Preview the generated pipeline
SERVICE=example-service PIPELINE_DRY_RUN=1 ./generate_pipeline.sh

# Package a service checkout without uploading
cd ../example-service
SERVICE=example-service PACKAGE_SKIP_UPLOAD=1 ../serverless-lambda-pipeline/scripts/serverless/package.sh

# This repo's checks
git ls-files -z '*.sh' '*.bash' | xargs -0 shellcheck
bats -r scripts test
scripts/ci/check-leaks.sh
```

The scripts target bash 3.2 (macOS) as well as Linux. Each script under
`scripts/` has a sibling `test-<name>.bats`.

## Repo CI

GitHub Actions (`.github/workflows/ci.yml`) runs shellcheck, the bats suite and
the leak check on every pull request and on pushes to `main`, on a stock
`ubuntu-latest` runner (shellcheck, `yq` v4, `zip` and `unzip` come with the
image; bats is installed with apt). The tests stub `buildkite-agent`, so no
Buildkite agent or pipeline is needed for this repo's own CI.

Leak-check false positives: add `<path>:<fixed string>` to `.leak-allowlist`.
Hits in that file on lines containing that string are then ignored. The
allowlist is public and is scanned like any other file, with no exemptions, so
`<fixed string>` must be surrounding context (e.g. `docs.md:example account`),
never the flagged value itself. A hit on a line holding nothing but the value,
or in a file whose path contains a 12-digit run, cannot be narrowly
allowlisted; change the file instead. Tracked symlinks fail the check (git
grep skips them, but their target text is public). Tracked paths containing `:` fail the check,
since hits are reported as `path:line`. Binary files cannot be checked
line by line: a tracked file git classifies as binary fails by path when it
matches any pattern (including the all-zeros placeholder or a longer digit
run), and cannot be allowlisted. `.gitattributes` changes that classification,
so review any change to it.

## Releasing

1. Open a PR, get it reviewed, and merge to `main`.
2. Tag the merge commit `vX.Y.Z` and push the tag. A repository ruleset keeps
   tags immutable.
3. Service repos move to the new release by changing the pinned
   `refs/tags/vX.Y.Z` in their bootstrap step.

## Upcoming: publish key layout

The publish step will store each zip once per production region bucket under:

```
serverless/<svc>/<ver>/<svc>-b<build>-<ver>-<sha>.zip
```

Production rolls out only through Terraform `s3_key` changes that reference
these keys.
