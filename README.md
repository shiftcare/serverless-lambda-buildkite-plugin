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
| `PACKAGE_ENV_PASSTHROUGH` | empty | Space- or comma-separated names of other bootstrap-step variables to copy into the package step's `env`. Each must be set, match `^[A-Z][A-Z0-9_]*$`, have a single-line value, and not be reserved (`AWS_*`, `BUILDKITE*`, `BK_*`, `PACKAGE_*`, `PIPELINE_*`, `LD_*`, `DYLD_*`, `SERVICE`, `SECRETS_PROVIDER_MODE`, `PATH`, `HOME`, `SHELL`, `IFS`, `ENV`, `BASH_ENV`, `NODE_OPTIONS`). **Never list a secret**: values are written into the generated pipeline YAML and are visible in the Buildkite UI. |

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

Buildkite does not pass the bootstrap step's `env` on to the steps it uploads.
If `serverless.yml` reads other `${env:...}` values at package time, set them
in the bootstrap step's `env` and list their names in
`PACKAGE_ENV_PASSTHROUGH`. Only non-secret values: they appear in the
generated pipeline YAML, which anyone with access to the build can read in the
Buildkite UI.

## How packaging withholds AWS credentials

`scripts/serverless/package.sh` runs in the service checkout and:

1. Unsets every `AWS_*` environment variable and sets
   `AWS_EC2_METADATA_DISABLED=true`, which tells the AWS SDKs not to use the
   instance metadata service (IMDS). It runs Serverless with an empty scratch
   `HOME`, so no `~/.aws` files exist for it. The SDKs Serverless uses
   therefore have no credential source. Then it exports `AWS_ACCOUNT_ID` (the
   placeholder) and `SECRETS_PROVIDER_MODE=placeholder`.
2. Runs `npm ci`, then the lockfile-pinned Serverless with
   `npx --no-install serverless`. There is never a global install. The build
   fails unless Serverless is major version 2.
3. Expects exactly one `.serverless/*.zip`. Individually packaged functions are
   not supported.
4. Refuses the zip if it contains `.serverless/`, `.env` (a file, or anything
   under a `.env/` directory), `.env.*`,
   `cloudformation-template-*.json` or `serverless-state.json`.
5. Copies the zip to `dist/<SERVICE>.zip` and adds `ci.build.info.txt` at its
   root. That file records the build number, commit, branch, Node and
   Serverless versions, and the UTC build time.
6. Uploads only `dist/<SERVICE>.zip` as a build artifact.

No Docker and no Docker Hub are involved. Agents need Node 22 with npm and npx
on `PATH`, plus `zip`, `unzip` and `yq` v4.

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
scripts/serverless/check-zip-contents.sh dist/example-service.zip reference.txt
```

The check ignores directory entries, `ci.build.info.txt`, blank lines and `#`
comments. It exits 0 on a match, 1 on a difference (with a unified diff:
`-` reference, `+` zip) and 2 on a usage error.

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

`.buildkite/pipeline.yml` runs shellcheck, the bats suite and the leak check
on queue `tiny`. Agents need `shellcheck`, `bats`, `yq` v4, `git`, `zip` and
`unzip`. The Buildkite pipeline is created by hand in the Buildkite UI, using
the default `buildkite-agent pipeline upload` step.

Leak-check false positives: add `<path>:<fixed string>` to `.leak-allowlist`.
Hits in that file on lines containing that string are then ignored. Review
every entry, since the allowlist is public too.

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
