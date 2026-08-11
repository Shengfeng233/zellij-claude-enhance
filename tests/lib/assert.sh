#!/usr/bin/env bash
# Shared test helpers. Source this from each test runner.
PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        echo "    expected: [$expected]"
        echo "    actual:   [$actual]"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        echo "    expected to contain: [$needle]"
        echo "    in:                  [$haystack]"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_contains() {
    local desc="$1" needle="$2" file="$3"
    if [[ -f "$file" ]] && grep -qF -- "$needle" "$file"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        echo "    expected file to contain: [$needle]"
        echo "    file: $file"
        FAIL=$((FAIL + 1))
    fi
}

report() {
    echo "  → $PASS passed, $FAIL failed"
    [[ "$FAIL" -eq 0 ]]
}
