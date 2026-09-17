#!/usr/bin/env bash
# deps.sh — oced_deps: idempotent dependency check/install, self-contained
# (no external installer scripts). Core: sqlite3, python3, jq, gzip.
# Menu (fzf) is optional and only needed for `opencode-db menu`.
set -uo pipefail

OCED_DEPS_CORE=(sqlite3 python3 jq gzip)
OCED_DEPS_OPTIONAL=(fzf)

oced_deps_usage() {
    cat <<'EOF'
Usage: opencode-db deps [--check]
  --check    only report missing tools (no sudo, no install); rc=0 if all core deps present
  (no flag)  install any missing dependency (Linux/apt, prompts for sudo); idempotent
EOF
}

oced_deps() {
    local check_only=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --check) check_only=1 ;;
            -h|--help) oced_deps_usage; return 0 ;;
            *) echo "Unknown argument: $1 (use --check)"; oced_deps_usage; return 1 ;;
        esac
        shift
    done

    local dep missing=0
    local -a to_install=()
    for dep in "${OCED_DEPS_CORE[@]}"; do
        if o_have "$dep"; then
            echo "   OK       $dep"
        else
            echo "   MISSING  $dep"
            missing=1
            to_install+=("$dep")
        fi
    done
    for dep in "${OCED_DEPS_OPTIONAL[@]}"; do
        if o_have "$dep"; then
            echo "   OK       $dep (menu)"
        else
            echo "   MISSING  $dep (menu, optional)"
            to_install+=("$dep")
        fi
    done

    echo ""
    if [ "$check_only" -eq 1 ]; then
        if [ "$missing" -eq 0 ]; then
            echo "All core dependencies present."
        else
            echo "Missing core dependencies. Run 'opencode-db deps' to install them (needs sudo)."
        fi
        return "$missing"
    fi

    if [ "$missing" -eq 0 ] && command -v fzf >/dev/null 2>&1; then
        echo "All dependencies present."
        return 0
    fi

    [ ${#to_install[@]} -eq 0 ] && { echo "All dependencies present."; return 0; }

    case "$(uname -s)" in
        Linux)
            if command -v apt-get >/dev/null 2>&1; then
                echo "-> Installing with apt (needs sudo): ${to_install[*]}"
                sudo apt-get install -y --no-install-recommends "${to_install[@]}"
                echo "✅ Dependencies installed."
            else
                echo "No apt-get found. Install manually: ${to_install[*]}"
                return 1
            fi
            ;;
        Darwin)
            echo "macOS: brew install ${to_install[*]}"
            return 1
            ;;
        *)
            echo "Unsupported OS. Install manually: ${to_install[*]}"
            return 1
            ;;
    esac
}