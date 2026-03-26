#!/usr/bin/env bash
#
# Calibrate arbbot workflow rates using screenzero.
#
# For each bot workflow file, extracts the current rates and compares them
# against fresh screenzero backtest results. Updates the workflow if rates
# have changed, but aborts if the change exceeds MAX_DEVIATION_PCT (safety).
#
# Usage: ./scripts/calibrate.sh <screenzero_binary> <workflow_dir>
#
set -euo pipefail

SCREENZERO="${1:?Usage: calibrate.sh <screenzero_binary> <workflow_dir>}"
WORKFLOW_DIR="${2:?Usage: calibrate.sh <screenzero_binary> <workflow_dir>}"

# Maximum allowed rate deviation (%). If a new rate deviates more than this
# from the old rate, the script aborts with an error to prevent bad updates.
MAX_DEVIATION_PCT="${MAX_DEVIATION_PCT:-1.0}"

changed=0

for workflow in "$WORKFLOW_DIR"/*.yml; do
  echo "=== Processing: $(basename "$workflow") ==="

  # Extract config from workflow env vars
  chain=$(grep 'ARBZERO_CHAIN:' "$workflow" | head -1 | awk '{print $2}' | tr -d '"' || true)
  spread=$(grep 'ARBZERO_SPREAD:' "$workflow" | head -1 | awk '{print $2}' | tr -d '"' || true)
  slippage=$(grep 'ARBZERO_SLIPPAGE:' "$workflow" | head -1 | awk '{print $2}' | tr -d '"' || true)
  home_token=$(grep 'ARBZERO_HOME_TOKEN:' "$workflow" | head -1 | awk '{print $2}' | tr -d '"' || true)
  satellites_json=$(grep 'ARBZERO_SATELLITES:' "$workflow" | head -1 | sed "s/.*ARBZERO_SATELLITES: *'//;s/'.*//") || true

  if [ -z "$chain" ] || [ -z "$spread" ] || [ -z "$home_token" ] || [ -z "$satellites_json" ]; then
    echo "  Skipping: missing required env vars (CHAIN, SPREAD, HOME_TOKEN, SATELLITES)"
    continue
  fi

  echo "  Chain: $chain, Spread: $spread%, Home: ${home_token:0:10}..."

  # Process each satellite
  num_satellites=$(echo "$satellites_json" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

  for idx in $(seq 0 $((num_satellites - 1))); do
    sat_token=$(echo "$satellites_json" | python3 -c "import sys,json; print(json.load(sys.stdin)[$idx]['token'])")
    old_sell=$(echo "$satellites_json" | python3 -c "import sys,json; print(json.load(sys.stdin)[$idx]['sell_home_at'])")
    old_buy=$(echo "$satellites_json" | python3 -c "import sys,json; print(json.load(sys.stdin)[$idx]['buy_home_at'])")

    echo "  Satellite $idx: ${sat_token:0:10}... (current: sell=$old_sell buy=$old_buy)"

    # Build screenzero args
    screenzero_args=(--chain "$chain" --tokens "$home_token,$sat_token" --days 30 --detail auto --json --spread "$spread")
    if [ -n "$slippage" ]; then
      screenzero_args+=(--slippage "$slippage")
    fi

    # Run screenzero to get new rates
    json_output=$("$SCREENZERO" "${screenzero_args[@]}" 2>/dev/null) || true

    if [ -z "$json_output" ]; then
      echo "  WARNING: screenzero returned no output, skipping"
      continue
    fi

    new_sell=$(echo "$json_output" | python3 -c "import sys,json; print(json.load(sys.stdin)['sell_home_at'])")
    new_buy=$(echo "$json_output" | python3 -c "import sys,json; print(json.load(sys.stdin)['buy_home_at'])")
    strategy=$(echo "$json_output" | python3 -c "import sys,json; print(json.load(sys.stdin)['strategy'])")

    echo "  New rates: sell=$new_sell buy=$new_buy (strategy: $strategy)"

    # Safety check: abort if deviation is too large
    python3 -c "
old_sell, new_sell = float('$old_sell'), float('$new_sell')
old_buy, new_buy = float('$old_buy'), float('$new_buy')
max_dev = float('$MAX_DEVIATION_PCT')

sell_dev = abs(new_sell - old_sell) / old_sell * 100
buy_dev = abs(new_buy - old_buy) / old_buy * 100

print(f'  Deviation: sell={sell_dev:.4f}%, buy={buy_dev:.4f}%')

if sell_dev > max_dev:
    print(f'  ABORT: sell rate deviation {sell_dev:.4f}% exceeds max {max_dev}%')
    exit(1)
if buy_dev > max_dev:
    print(f'  ABORT: buy rate deviation {buy_dev:.4f}% exceeds max {max_dev}%')
    exit(1)
print('  Deviation within limits.')
"

    # Update the satellites JSON in the workflow
    if [ "$old_sell" != "$new_sell" ] || [ "$old_buy" != "$new_buy" ]; then
      echo "  Updating rates..."
      new_satellites=$(echo "$satellites_json" | python3 -c "
import sys, json
sats = json.load(sys.stdin)
sats[$idx]['sell_home_at'] = '$new_sell'
sats[$idx]['buy_home_at'] = '$new_buy'
print(json.dumps(sats))
")
      python3 -c "
import sys
old = sys.argv[1]
new = sys.argv[2]
path = sys.argv[3]
with open(path) as f:
    content = f.read()
content = content.replace(old, new)
with open(path, 'w') as f:
    f.write(content)
" "$satellites_json" "$new_satellites" "$workflow"
      satellites_json="$new_satellites"
      changed=1
      echo "  Updated."
    else
      echo "  No change needed."
    fi
  done
  echo
done

if [ "$changed" -eq 1 ]; then
  echo "Rates were updated. Ready to commit."
  exit 0
else
  echo "All rates are current. No changes."
  exit 0
fi
