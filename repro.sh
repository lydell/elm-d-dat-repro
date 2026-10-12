#!/usr/bin/env bash

if [ $# -ne 2 ]; then
  echo "Usage (from small/ or big/): ../repro.sh FILE RUNS" >&2
  exit 1
fi

file="$1"
runs="$2"
locked=0
type_errors=0
other=0
success=0

for i in $(seq "$runs"); do
  printf "\r$(basename "$PWD") $file GHCRTS=${GHCRTS:-} – file is locked: $locked/$runs, type errors: $type_errors, other errors: $other, success: $success"
  rm -rf elm-stuff
  if ! elm make --output=/dev/null "$file" >/dev/null 2>stderr.txt; then
    if grep -q 'file is locked' stderr.txt; then
      locked=$((locked + 1))
      cp stderr.txt locked-error.txt
    elif grep -q '^-- TYPE MISMATCH' stderr.txt; then
      type_errors=$((type_errors + 1))
    else
      other=$((other + 1))
      cp stderr.txt other-error.txt
    fi
  else
    success=$((success + 1))
  fi
done

rm -f stderr.txt
