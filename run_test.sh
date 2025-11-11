#!/bin/bash

#!/usr/bin/env bash
set -euo pipefail

# ---------- Config ----------
JAR=${JAR:-target/rmlmapper-8.0.0-r381-all.jar}
IN=${IN:-rules.ttl}
OUT=${OUT:-test_out.ttl}
SER=${SER:-turtle}
VERBOSE_FLAG=${VERBOSE_FLAG:--v}
EXTRA_JAVA_OPTS=${JAVA_OPTS:-}
LOGDIR=${LOGDIR:-run_metrics}
mkdir -p "$LOGDIR"

RUN_ID=$(date +%Y%m%dT%H%M%S)
TIMESTAMP=$(date -Is)
TIME_LOG="$LOGDIR/time-$RUN_ID.txt"
METRICS_JSON="$LOGDIR/metrics-$RUN_ID.json"
METRICS_CSV="$LOGDIR/metrics.csv"

# ---------- Helpers ----------
stat_size() {
  local f="$1"
  if [[ -f "$f" ]]; then
    if stat -c%s "$f" >/dev/null 2>&1; then stat -c%s "$f"
    elif stat -f%z "$f" >/dev/null 2>&1; then stat -f%z "$f"
    else wc -c <"$f" | tr -d ' '
    fi
  else
    echo 0
  fi
}

have_gnu_time() { [[ -x /usr/bin/time ]] && /usr/bin/time --version >/dev/null 2>&1; }

# Count triples in a Turtle file using available tooling:
# 1) Apache Jena: riot --formatted=NTRIPLES file.ttl | wc -l
# 2) Raptor:      rapper -i turtle -o ntriples file.ttl | wc -l
# 3) rdflib:      rdfpipe -i turtle -o nt file.ttl | wc -l
# 4) Fallback heuristic: count lines that end with '.' (imperfect but works for many TTLs)
count_triples_ttl() {
  local f="$1"
if [[ ! -f "$f" ]]; then echo 0; return; fi
  # Heuristic fallback: count ttl statements ending with '.' ignoring prefixes and comments
  # Note: this is not fully spec-compliant; prefer one of the tools above for accuracy.
  grep -E '^\s*[^#].*\.\s*$' "$f" | wc -l | tr -d ' '
}

JAVA_VERSION=$(java -version 2>&1 | head -n1 | sed 's/"/\\"/g')

# Minimal GC logging off by default to keep things simple; uncomment if you want it.
# GC_OPTS="-Xlog:gc*:file=$LOGDIR/gc-$RUN_ID.log:time,uptime,level,tags" # Java 9+
# or for Java 8: GC_OPTS="-Xloggc:$LOGDIR/gc-$RUN_ID.log -XX:+PrintGCDetails -XX:+PrintGCDateStamps"
GC_OPTS=${GC_OPTS:-}

JAVA_CMD=(java $EXTRA_JAVA_OPTS $GC_OPTS -jar "$JAR" -m "$IN" -o "$OUT" -s "$SER" "$VERBOSE_FLAG")

# ---------- Pre-run ----------
IN_SIZE=$(stat_size "$IN")
OUT_SIZE_BEFORE=$(stat_size "$OUT") # may be 0 if not existing

# ---------- Run with timing ----------
EXIT_CODE=0
if have_gnu_time; then
  /usr/bin/time -v -o "$TIME_LOG" -- "${JAVA_CMD[@]}" || EXIT_CODE=$?
else
  { time -p "${JAVA_CMD[@]}"; } >"$TIME_LOG" 2>&1 || EXIT_CODE=$?
fi

# ---------- Post-run ----------
OUT_SIZE=$(stat_size "$OUT")
TRIPLES=$(count_triples_ttl "$OUT")

# Parse timing
WALL_SEC=""
USER_SEC=""
SYS_SEC=""
MAX_RSS_KB=""

if have_gnu_time; then
  # Extract values from GNU time -v output
  # Elapsed may be H:MM:SS or M:SS
  ELAPSED=$(awk -F': ' '/Elapsed \(wall clock\) time/ {print $2}' "$TIME_LOG")
  IFS=: read -r A B C <<<"$ELAPSED"
  if [[ -n "${C:-}" ]]; then
    WALL_SEC=$((10#$A*3600 + 10#$B*60 + 10#$C))
  else
    WALL_SEC=$((10#${A:-0}*60 + 10#${B:-0}))
  fi
  USER_SEC=$(awk -F': ' '/User time \(seconds\)/ {print $2}' "$TIME_LOG")
  SYS_SEC=$(awk -F': '  '/System time \(seconds\)/ {print $2}' "$TIME_LOG")
  MAX_RSS_KB=$(awk -F': ' '/Maximum resident set size/ {print $2}' "$TIME_LOG")
else
  WALL_SEC=$(awk '/^real/ {print $2}' "$TIME_LOG")
  USER_SEC=$(awk '/^user/ {print $2}' "$TIME_LOG")
  SYS_SEC=$(awk  '/^sys/  {print $2}' "$TIME_LOG")
  MAX_RSS_KB=""
fi

# ---------- Save JSON ----------
cat > "$METRICS_JSON" <<EOF
{
  "run_id": "$RUN_ID",
  "timestamp": "$TIMESTAMP",
  "command": "$(printf '%q ' "${JAVA_CMD[@]}")",
  "exit_code": $EXIT_CODE,
  "timing": {
    "wall_seconds": ${WALL_SEC:-null},
    "user_seconds": ${USER_SEC:-null},
    "sys_seconds": ${SYS_SEC:-null},
    "max_rss_kb": ${MAX_RSS_KB:-null}
  },
  "artifacts": {
    "jar": "$JAR",
    "input_path": "$IN",
    "input_size_bytes": $IN_SIZE,
    "output_path": "$OUT",
    "output_size_bytes": $OUT_SIZE,
    "output_triples": $TRIPLES
  },
  "java": {
    "version_header": "$JAVA_VERSION"
  }
}
EOF

# ---------- Save/append CSV ----------
# Header if file doesn't exist
if [[ ! -f "$METRICS_CSV" ]]; then
  echo "run_id,timestamp,exit_code,wall_seconds,user_seconds,sys_seconds,max_rss_kb,input_size_bytes,output_size_bytes,output_triples,jar,input,output" > "$METRICS_CSV"
fi
echo "$RUN_ID,$TIMESTAMP,$EXIT_CODE,${WALL_SEC:-},${USER_SEC:-},${SYS_SEC:-},${MAX_RSS_KB:-},$IN_SIZE,$OUT_SIZE,$TRIPLES,$JAR,$IN,$OUT" >> "$METRICS_CSV"

echo "Done."
echo "JSON: $METRICS_JSON"
echo "CSV:  $METRICS_CSV"
