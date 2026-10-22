#!/bin/sh
# Capture the README screenshots from synthetic data only.
#
# Runs the SICH_E2E capture (demo board seeds + demo quota) inside a sandbox so
# nothing from the operator's machine reaches the images:
#   - CFFIXED_USER_HOME points NSHomeDirectory() at an empty synthetic home, so
#     no real ~/.sich profiles, event feed or task book are read;
#   - SICH_REPO_ROOT names a synthetic project, so the live card is not this repo;
#   - SHELL is a fake agent that prints a scripted transcript instead of a real
#     login prompt (which would show user@hostname).
#
# Output: assets/screenshots/{board,drill-in}.png
set -e
cd "$(dirname "$0")/.."
app_dir=$(pwd)
out="$app_dir/../assets/screenshots"
sandbox="$app_dir/.artifacts/readme"
home="$sandbox/home"
project="$home/payments-api"

rm -rf "$sandbox"
mkdir -p "$project" "$out"
touch "$project/pyproject.toml"

fake_agent="$sandbox/fake-agent.sh"
cat > "$fake_agent" <<'EOF'
#!/bin/sh
stty -echo
d=$(printf '\033[2m'); b=$(printf '\033[1m'); r=$(printf '\033[0m')
o=$(printf '\033[38;5;173m'); g=$(printf '\033[32m'); red=$(printf '\033[31m'); c=$(printf '\033[36m')
cat <<T
${d}>${r} Add idempotency keys to the refund endpoint and cover the retry path

${o}⏺${r} I'll start by reading the refund handler and its tests.

${g}⏺${r} ${b}Read${r}(src/payments/refunds.py)
  ${d}⎿  Read 142 lines${r}

${g}⏺${r} ${b}Search${r}(pattern: "idempotency", path: "src/")
  ${d}⎿  Found 3 files${r}

${g}⏺${r} ${b}Update${r}(src/payments/refunds.py)
  ${d}⎿  Updated src/payments/refunds.py with 18 additions and 4 removals${r}
     ${d}41${r}  ${red}-    refund = gateway.refund(charge_id, amount)${r}
     ${d}41${r}  ${g}+    key = request.headers.get("Idempotency-Key")${r}
     ${d}42${r}  ${g}+    if cached := store.lookup(key):${r}
     ${d}43${r}  ${g}+        return cached${r}
     ${d}44${r}  ${g}+    refund = gateway.refund(charge_id, amount, key=key)${r}

${g}⏺${r} ${b}Bash${r}(pytest tests/test_refunds.py -q)
  ${d}⎿  ............                                  [100%]
     12 passed in 0.84s${r}

${o}⏺${r} Refunds are now idempotent: a repeated request with the same
  ${c}Idempotency-Key${r} returns the original refund instead of charging twice.
  Added two tests for the retry path; all 12 pass.

${d}╭─────────────────────────────────────────────────────────────╮${r}
${d}│${r} >                                                           ${d}│${r}
${d}╰─────────────────────────────────────────────────────────────╯${r}
  ${d}? for shortcuts${r}
T
exec cat > /dev/null
EOF
chmod +x "$fake_agent"

swift build
CFFIXED_USER_HOME="$home" SICH_REPO_ROOT="$project" SHELL="$fake_agent" \
    SICH_E2E=1 .build/debug/sich

shots="$project/app/.artifacts/e2e"
cp "$shots/01-board.png" "$out/board.png"
cp "$shots/02-drillin-terminal.png" "$out/drill-in.png"
echo "wrote $out/board.png $out/drill-in.png"
