# TypeScript 7.0.2 skips a JSON output depending on file-loading order

`tsc` 7.0.2 sometimes does not write a JSON file to `outDir`. The JSON file is imported by a declaration file, and that declaration file is reached two ways: through a package in `node_modules`, and directly from the project.

```
src/main.ts                        imports "consumer" and "./local"
src/local.ts                       export { data } from "shared"
node_modules/consumer/index.d.ts   export { data } from "shared"
prebuilt/shared/index.d.ts         import data from "./data.json"   ("shared" maps here through paths)
prebuilt/shared/data.json          expected at out/prebuilt/shared/data.json
```

`--explainFiles` lists `data.json` in the program even on compiles that do not write it. Only the emit changes.

## See it in CI

The [workflow](.github/workflows/repro.yml) runs one job per compiler and mode. Each job compiles the project 30 times per import order and fails when any compile skipped `data.json`. Each job's summary on the run page shows the counts and one mark per compile (`W` written, `.` skipped).

From [this run](https://github.com/eliseuvideira1/ts7-json-emit-repro/actions/runs/42379626093) on GitHub-hosted `ubuntu-latest` (2 cores), compiles out of 30 that wrote `data.json`:

| Compiler | `consumer` imported first | `./local` imported first |
|---|---|---|
| 7.0.2 | 21/30 | 8/30 |
| 7.0.2 `--singleThreaded` | 30/30 | 0/30 |
| 7.1.0-dev.20261005.1 | 23/30 | 4/30 |
| 7.1.0-dev.20261005.1 `--singleThreaded` | 30/30 | 0/30 |
| 7.1.0-dev.20261006.1 | 30/30 | 30/30 |
| 7.1.0-dev.20261006.1 `--singleThreaded` | 30/30 | 30/30 |
| 7.1.0-beta | 30/30 | 30/30 |
| 7.1.0-beta `--singleThreaded` | 30/30 | 30/30 |
| 6.0.3 | 30/30 | 30/30 |

The two nightlies bracket microsoft/TypeScript#64632. 7.1.0-dev.20261005.1 is built 3 commits before it and fails like 7.0.2. 7.1.0-dev.20261006.1 is built 1 commit after it and passes. Of the 4 commits between the two builds, only #64632 changes the file loader.

The `variables` job changes one input at a time. `paths` vs relative imports, a 500 KB JSON file, and 2,000 extra modules all still flake. `GOMAXPROCS=1` is not a workaround. Like `--singleThreaded`, it writes the file on every compile with `consumer` first and skips it on every compile with `./local` first.

## See it locally

With `--singleThreaded` and `./local` imported first, 7.0.2 skips `data.json` on every compile, so one compile shows the bug:

```sh
npm install --prefix /tmp/ts-7.0.2 typescript@7.0.2
ORDER=local-first ./repro.sh /tmp/ts-7.0.2/node_modules/typescript/bin/tsc 1 --singleThreaded
```

Without `--singleThreaded`, the result changes from compile to compile:

```sh
./repro.sh /tmp/ts-7.0.2/node_modules/typescript/bin/tsc 30
```

`repro.sh` prints `W` for each compile that wrote `data.json` and `.` for each that did not.

## Cause

In 7.0.2 the file loader starts a file's imports once, at the depth of the first arrival. A file first reached through `node_modules` passes that depth to its imports. When the same file is reached later from the project, its own depth drops, but its imports keep the first depth, so `data.json` counts as a library file and is not emitted.

Which path arrives first decides the result. `--singleThreaded` loads a file's last import first, because its work queue pops from the end (`internal/core/workgroup.go`). So with `./local` imported first in `src/main.ts`, the `consumer` path arrives first and every compile skips `data.json`. Without `--singleThreaded`, the order is a race.

This is microsoft/TypeScript#64498, fixed by microsoft/TypeScript#64632 (in 7.1.0-beta, not in 7.0.2).
