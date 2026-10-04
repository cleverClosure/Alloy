#!/usr/bin/env bash
# SSE2 corpus verdicts and synthetic controls; no Wine invocation.
# Author: Timur Isaev

isa_corpus_verdict() { # label log exit expected-checksum mutation
  local label=$1 log=$2 rc=$3 checksum=$4 mutation=$5 line failures actual mutation_tag
  local pattern='^cpu-001 isa-corpus sse2: cases=12736 failures=([0-9]+) checksum=([0-9a-f]{16}) mutate=(none|paddb)$'
  line=$(grep '^cpu-001 isa-corpus sse2:' "$log" || true)
  line=${line%$'\r'}
  if [[ ! $line =~ $pattern ]]; then
    echo "FAIL: $label has no single complete SSE2 summary" >&2
    return 1
  fi
  failures=${BASH_REMATCH[1]}
  actual=${BASH_REMATCH[2]}
  mutation_tag=${BASH_REMATCH[3]}
  if [[ -z $checksum || $actual != "$checksum" || $mutation_tag != "$mutation" ]]; then
    echo "FAIL: $label does not match its native oracle and mutation tag" >&2
    return 1
  fi
  if [[ $mutation == none ]]; then
    if [[ $rc != 0 || $failures != 0 ]] || grep -q '^FAIL' "$log"; then
      echo "FAIL: $label must exit 0 with zero failures and no FAIL lines" >&2
      return 1
    fi
  elif [[ $rc != 1 || $failures == 0 ]] || ! grep -Eq '^FAIL (hand-vector )?paddb[[:space:]]' "$log"; then
    echo "FAIL: $label must exit 1 and report the paddb mutation by name" >&2
    return 1
  fi
  echo "PASS: $label matches its native oracle and expected outcome"
}

isa_corpus_verdict_selftest() {
  local temp failures=0 result expected label rc mutation checksum
  temp=$(mktemp -d)
  for label in clean mutation timeout crash silent-counter missing-name wrong-checksum missing-summary duplicate-summary; do
    rc=0 mutation=none checksum=21ba41417def5d07 expected=0
    printf 'cpu-001 isa-corpus sse2: cases=12736 failures=0 checksum=%s mutate=none\n' "$checksum" >"$temp/log"
    case "$label" in
      mutation | timeout | crash | missing-name)
        rc=1 mutation=paddb checksum=eb480915973927bd
        printf 'FAIL hand-vector paddb expected=00 got=01\ncpu-001 isa-corpus sse2: cases=12736 failures=1 checksum=%s mutate=paddb\n' "$checksum" >"$temp/log"
        if [[ $label == timeout ]]; then rc=142 expected=1; fi
        if [[ $label == crash ]]; then rc=139 expected=1; fi
        if [[ $label == missing-name ]]; then
          sed -i '' 's/FAIL hand-vector paddb/FAIL hand-vector psubq/' "$temp/log"
          expected=1
        fi
        ;;
      silent-counter)
        echo 'FAIL paddb expected=00 got=01' >>"$temp/log"
        expected=1
        ;;
      wrong-checksum) checksum=0000000000000000 expected=1 ;;
      missing-summary)
        : >"$temp/log"
        expected=1
        ;;
      duplicate-summary)
        cp "$temp/log" "$temp/second"
        cat "$temp/second" >>"$temp/log"
        expected=1
        ;;
    esac
    result=0
    isa_corpus_verdict "$label" "$temp/log" "$rc" "$checksum" "$mutation" >"$temp/result" 2>&1 || result=$?
    if [[ $result != "$expected" ]]; then
      echo "FAIL selftest: $label expected=$expected actual=$result"
      cat "$temp/result"
      failures=$((failures + 1))
    else
      echo "PASS selftest: $label"
    fi
  done
  rm -rf "$temp"
  [[ $failures == 0 ]]
}
