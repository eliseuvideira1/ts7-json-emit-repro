#!/usr/bin/env bash
# Compiles a tiny project <runs> times and counts how often tsc writes out/prebuilt/shared/data.json.
#
# Usage: ./repro.sh <path to typescript/bin/tsc> <runs> [extra tsc flags...]
#
# Project knobs (environment):
#   ORDER    package-first (default) or local-first: which of the two imports comes first in src/main.ts
#   LINK     paths (default) or relative: how both importers reach prebuilt/shared/index.d.ts
#   FILLERS  number of extra modules imported by src/main.ts (default 0)
#   JSON_KB  size of data.json in KB (default 1)
set -eu

tsc=$1
runs=$2
shift 2

ORDER=${ORDER:-package-first}
LINK=${LINK:-paths}
FILLERS=${FILLERS:-0}
JSON_KB=${JSON_KB:-1}

write_project() {
  dir=$1
  mkdir -p "$dir/src/fillers" "$dir/prebuilt/shared" "$dir/node_modules/consumer"

  cat > "$dir/tsconfig.json" <<'EOF'
{
  "compilerOptions": {
    "module": "commonjs",
    "moduleResolution": "bundler",
    "resolveJsonModule": true,
    "skipLibCheck": true,
    "types": [],
    "rootDir": ".",
    "outDir": "out",
    "paths": { "shared": ["./prebuilt/shared/index.d.ts"] }
  },
  "files": ["src/main.ts"]
}
EOF

  # Prebuilt output of another project: a declaration file that imports a JSON file beside it.
  cat > "$dir/prebuilt/shared/index.d.ts" <<'EOF'
import data from "./data.json";
export { data };
EOF
  node -e '
    const target = Number(process.argv[1]) * 1024;
    const entries = [];
    let i = 0;
    while (JSON.stringify({ entries }).length < target) {
      entries.push({ id: i, label: "entry-" + String(i).padStart(7, "0") });
      i++;
    }
    process.stdout.write(JSON.stringify({ entries }));
  ' "$JSON_KB" > "$dir/prebuilt/shared/data.json"

  if [ "$LINK" = paths ]; then
    from_package='shared'
    from_local='shared'
  else
    from_package='../../prebuilt/shared'
    from_local='../prebuilt/shared'
  fi

  # Path 1: a package in node_modules re-exports the prebuilt declaration file.
  echo '{ "name": "consumer", "version": "1.0.0", "types": "index.d.ts" }' > "$dir/node_modules/consumer/package.json"
  echo "export { data } from \"$from_package\";" > "$dir/node_modules/consumer/index.d.ts"

  # Path 2: a local file re-exports the same prebuilt declaration file.
  echo "export { data } from \"$from_local\";" > "$dir/src/local.ts"

  : > "$dir/src/fillers/index.ts"
  i=0
  while [ "$i" -lt "$FILLERS" ]; do
    printf 'export interface Shape%s { id: number; name: string }\nexport const make%s = (id: number): Shape%s => ({ id, name: "f%s" });\n' "$i" "$i" "$i" "$i" > "$dir/src/fillers/f$i.ts"
    echo "export * from \"./f$i\";" >> "$dir/src/fillers/index.ts"
    i=$((i + 1))
  done

  {
    echo 'import "./fillers";'
    if [ "$ORDER" = package-first ]; then
      echo 'import { data as viaPackage } from "consumer";'
      echo 'import { data as viaLocal } from "./local";'
    else
      echo 'import { data as viaLocal } from "./local";'
      echo 'import { data as viaPackage } from "consumer";'
    fi
    echo 'export const counts = [viaPackage.entries.length, viaLocal.entries.length];'
  } > "$dir/src/main.ts"
}

dir=$(mktemp -d)
write_project "$dir"

written=0
marks=""
run=1
while [ "$run" -le "$runs" ]; do
  rm -rf "$dir/out"
  status=0
  (cd "$dir" && node "$tsc" -p tsconfig.json "$@" > "$dir/tsc.log" 2>&1) || status=$?
  if [ "$run" -eq 1 ] && { [ "$status" -ne 0 ] || [ -s "$dir/tsc.log" ]; }; then
    echo "tsc output on run 1 (exit $status):"
    cat "$dir/tsc.log"
  fi
  if [ -f "$dir/out/prebuilt/shared/data.json" ]; then
    written=$((written + 1))
    marks="${marks}W"
  else
    marks="${marks}."
  fi
  run=$((run + 1))
done

echo "$(node "$tsc" --version) $* ORDER=$ORDER LINK=$LINK FILLERS=$FILLERS JSON_KB=$JSON_KB GOMAXPROCS=${GOMAXPROCS:-unset}: data.json written $written/$runs  $marks"
