#!/bin/bash
# Fake Claude Code session for the promo footage (see promo-footage.sh). It mimics
# the real 2.x terminal UI — block-art header, ⏺/⎿ tool lines, diff bands, the
# spinner, the ruled input box and the permission/question dialogs — and picks its
# transcript from the card's directory name. It runs no agent and spends no quota.
#
# Every card spawns at 80 columns; the transcript waits for the drill-in resize
# so it is drawn once, at the real width, like a TUI repainting on SIGWINCH.

ESC=$'\033'
r="$ESC[0m"; b="$ESC[1m"; nb="$ESC[22m"
orange="$ESC[38;2;215;119;87m"; gray="$ESC[38;2;153;153;153m"; dim="$ESC[38;2;110;110;110m"
ruleC="$ESC[38;2;136;136;136m"; white="$ESC[38;2;255;255;255m"; green="$ESC[38;2;78;186;101m"
red="$ESC[38;2;255;107;128m"; blue="$ESC[38;2;177;185;249m"; amber="$ESC[38;2;255;193;7m"
addBg="$ESC[48;2;34;92;43m"; delBg="$ESC[48;2;122;41;54m"; band="$ESC[48;2;55;55;55m"

stty -echo
cols=0
until [ "$cols" -ge 100 ]; do
    sleep 0.05
    cols=$(stty size 2>/dev/null | cut -d' ' -f2)
    cols=${cols:-0}
done
printf '%s' "$ESC[?25l"

line() { printf '%s\n' "$1"; }
pad() { printf "%-$(( $2 ))s" "$1"; }
rule() { printf '%s%s%s\n' "${1:-$ruleC}" "$(printf '─%.0s' $(seq "$cols"))" "$r"; }

header() {
    line " ${orange}▐▛███▜▌${r}   ${b}Claude Code${nb} ${gray}v2.1.306${r}"
    line "${orange}▝▜█████▛▘${r}  ${gray}Opus 5.5 · Claude Max${r}"
    line "  ${orange}▘▘ ▝▝${r}    ${gray}~/$(basename "$PWD")${r}"
    line ""
}

you() {
    printf '%s%s❯ %s%s%s\n\n' "$band" "$gray" "$white" "$(pad "$1" $(( cols - 2 )))" "$r"
}
say() { line "${white}⏺${r} $1"; line ""; }
tool() {
    line "${green}⏺${r} ${b}$1${nb}($2)"
    line "  ${gray}⎿${r}  $3"
    [ -n "$4" ] || line ""
}
diffline() { # kind number text
    local text="$3" bg="" sign=" "
    [ "$1" = "+" ] && { bg="$addBg"; sign="+"; }
    [ "$1" = "-" ] && { bg="$delBg"; sign="-"; }
    printf '       %s%s%s %s%s%s\n' "$gray" "$2" "$r" "$bg" "$(pad "$sign $text" $(( cols - 12 )))" "$r"
}

# The bottom chrome while the agent works: spinner, blank, the input box, footer.
# The cursor parks at the end of the footer, five lines below the spinner.
frame() {
    printf '%s%s %s… %s(esc to interrupt)%s\n\n' "$orange" "${1:-✻}" "${2:-Working}" "$gray" "$r"
    rule; line "${gray}❯${r} "; rule
    printf '  %s⏵⏵ accept edits on%s %s(shift+tab to cycle)%s' "$amber" "$r" "$gray" "$r"
}
unframe() { printf '\r%s[5A%s[J' "$ESC" "$ESC"; }
# Print lines above the chrome: `emit` swaps the chrome out, prints, redraws it.
emit() { unframe; for l in "$@"; do line "$l"; done; frame "✻" "$verb"; }
spin() { # seconds
    local glyphs=(✢ ✳ ✶ ✻ ✽ ✻ ✶ ✳) i=0 end=$(( $1 * 10 ))
    while [ "$i" -lt "$end" ]; do
        printf '\r%s[5A%s[K%s%s %s… %s(esc to interrupt)%s\r%s[5B' \
            "$ESC" "$ESC" "$orange" "${glyphs[$(( i % 8 ))]}" "$verb" "$gray" "$r" "$ESC"
        printf '%s[%sG' "$ESC" 1
        sleep 0.1
        i=$(( i + 1 ))
    done
}
working() { verb="$1"; frame "✻" "$verb"; }
done_working() { unframe; }

# The idle input box; returns with the cursor after "❯ " and echo on.
ask() {
    rule; line "${gray}❯${r} "; rule
    printf '  %s⏵⏵ accept edits on%s %s(shift+tab to cycle)%s' "$amber" "$r" "$gray" "$r"
    printf '\r%s[2A%s[3G%s[?25h' "$ESC" "$ESC" "$ESC"
    stty echo
    IFS= read -r reply
    stty -echo
    printf '%s[?25l\r%s[2A%s[J' "$ESC" "$ESC" "$ESC"
    you "$reply"
}
idle() {
    rule; line "${gray}❯${r} "; rule
    printf '  %s⏵⏵ accept edits on%s %s(shift+tab to cycle)%s' "$amber" "$r" "$gray" "$r"
    printf '\r%s[2A%s[3G%s[?25h' "$ESC" "$ESC" "$ESC"
    exec cat > /dev/null
}

# A dialog of N lines that waits for one key, then disappears like the real one.
dialog_wait() { # line-count
    IFS= read -rsn1 _key
    printf '\r%s[%sA%s[J' "$ESC" "$1" "$ESC"
}

payments() {
    header
    you "Add idempotency keys to the refund endpoint and cover the retry path"
    say "I'll read the refund handler and its tests first."
    tool Read "src/payments/refunds.py" "Read ${b}142${nb} lines"
    tool Update "src/payments/refunds.py" "Updated src/payments/refunds.py with ${b}4${nb} additions and ${b}1${nb} removal" nobreak
    diffline " " 39 "def refund(charge_id: str, amount: int, request: Request):"
    diffline - 40 "    refund = gateway.refund(charge_id, amount)"
    diffline + 40 "    key = request.headers[\"Idempotency-Key\"]"
    diffline + 41 "    if cached := store.lookup(key):"
    diffline + 42 "        return cached"
    diffline + 43 "    refund = gateway.refund(charge_id, amount, key=key)"
    diffline " " 44 "    return store.save(key, refund)"
    line ""
    working "Running tests"; spin 1
    emit "${green}⏺${r} ${b}Bash${nb}(pytest tests/test_refunds.py -q)" "  ${gray}⎿${r}  ${green}13 passed${r} in 0.91s" ""
    spin 1
    done_working
    say "Done. A retried refund with the same ${blue}Idempotency-Key${r} now returns the original refund instead of charging twice. 13 tests pass."
    ask
    working "Adding retry logging"; spin 1
    emit "${green}⏺${r} ${b}Update${nb}(src/payments/refunds.py)" "  ${gray}⎿${r}  Updated src/payments/refunds.py with ${b}2${nb} additions" ""
    spin 600
}

auth() {
    header
    you "Rotate refresh tokens on every use and revoke the whole family on reuse"
    tool Read "src/auth/tokens.py" "Read ${b}96${nb} lines"
    tool Update "src/auth/tokens.py" "Updated src/auth/tokens.py with ${b}31${nb} additions and ${b}6${nb} removals"
    tool Write "migrations/0042_token_families.sql" "Wrote ${b}18${nb} lines to migrations/0042_token_families.sql"
    say "The rotation needs a ${blue}token_families${r} table before the tests can run."
    rule "$blue"
    line " ${b}${blue}Bash command${r}"
    line ""
    line "   psql auth_dev -f migrations/0042_token_families.sql"
    line "   ${gray}Create the token_families table in the dev database${r}"
    line ""
    line " Do you want to proceed?"
    line " ${blue}❯ 1. Yes${r}"
    line "   2. Yes, and don't ask again for ${b}psql${nb} commands in this project"
    line "   3. No, and tell Claude what to do differently ${gray}(esc)${r}"
    dialog_wait 10
    tool Bash "psql auth_dev -f migrations/0042_token_families.sql" "CREATE TABLE"
    working "Running tests"; spin 2
    emit "${green}⏺${r} ${b}Bash${nb}(pytest tests/auth -q)" "  ${gray}⎿${r}  ${green}27 passed${r} in 1.84s" ""
    spin 600
}

quota() {
    header
    you "Show one gauge for subscription and API credit together"
    tool Read "src/quota/pools.py" "Read ${b}211${nb} lines"
    tool Grep "\"headroom\"" "Found ${b}6${nb} files"
    say "Both pools can serve the same request, so the aggregate needs an order."
    rule "$blue"
    line " ${blue}☐ Pool order${r}"
    line ""
    line " ${b}When both pools have headroom, which should the aggregate draw from first?${nb}"
    line ""
    line " ${blue}❯ 1. Subscription first${r}"
    line "      ${gray}Spend the Max plan before any API credit${r}"
    line "   2. API credit first"
    line "      ${gray}Keep the subscription for interactive work${r}"
    line "   3. Type something."
    dialog_wait 10
    line "${white}⏺${r} User answered: ${b}Subscription first${nb}"
    line ""
    tool Update "src/quota/aggregate.py" "Updated src/quota/aggregate.py with ${b}24${nb} additions"
    working "Wiring the gauge"; spin 600
}

ratelimit() {
    header
    ask
    say "I'll find where API keys are resolved and add a per-key limiter there."
    working "Exploring"; spin 1
    emit "${green}⏺${r} ${b}Read${nb}(src/api/middleware.py)" "  ${gray}⎿${r}  Read ${b}74${nb} lines" ""
    spin 1
    emit "${green}⏺${r} ${b}Write${nb}(src/api/ratelimit.py)" "  ${gray}⎿${r}  Wrote ${b}46${nb} lines to src/api/ratelimit.py" ""
    spin 600
}

background() {
    header
    you "Keep going with the current task"
    working "Working"; spin 6000
}

case "$(basename "$PWD")" in
    payments-api) payments ;;
    auth-service) auth ;;
    quota-aggregation) quota ;;
    public-api) ratelimit ;;
    *) background ;;
esac
idle
