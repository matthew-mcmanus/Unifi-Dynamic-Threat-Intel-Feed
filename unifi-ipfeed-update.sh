#!/usr/bin/env bash
set -euo pipefail

# --- CONFIG (edit as needed) -----------------------------------------------
GROUP_ID="PLACE YOURS HERE"
FEED_URL="https://raw.githubusercontent.com/firehol/blocklist-ipsets/refs/heads/master/firehol_level1.netset"
MONGO_URI="mongodb://127.0.0.1:27117/ace"

# You can set this to either the binary OR the directory that contains it:
#   /usr/local/sbin/unifi-ipfeed/mongosh/bin/mongosh   (binary)
#   /usr/local/sbin/unifi-ipfeed/mongosh               (directory; script will resolve to /bin/mongosh)
MONGOSH_BIN="/usr/local/sbin/unifi-ipfeed/mongosh"

MAX_ENTRIES=50000        # how many from the feed to keep after de-dupe
BATCH_SIZE=1000          # how many members to add/remove per Mongo command
CACHE_DIR="/usr/local/sbin/unifi-ipfeed/cache"   # where we cache the fetched feed/etag
# ---------------------------------------------------------------------------

# Resolve MONGOSH_BIN if a directory was provided
if [ -d "$MONGOSH_BIN" ]; then
  if [ -x "$MONGOSH_BIN/bin/mongosh" ]; then
    MONGOSH_BIN="$MONGOSH_BIN/bin/mongosh"
  else
    echo "ERROR: mongosh directory '$MONGOSH_BIN' does not contain bin/mongosh" >&2
    exit 1
  fi
fi

[ -x "$MONGOSH_BIN" ] || { echo "ERROR: mongosh not found or not executable at $MONGOSH_BIN"; exit 1; }
mkdir -p "$CACHE_DIR"

FEED_RAW="$CACHE_DIR/feed.netset"
ETAG_FILE="$CACHE_DIR/feed.etag"
NEW_LIST="$(mktemp)"; trap 'rm -f "$NEW_LIST" "$CURRENT_TMP" "$TOADD" "$TOREM"' EXIT
CURRENT_TMP="$(mktemp)"
TOADD="$(mktemp)"
TOREM="$(mktemp)"

echo "==> Fetching feed (ETag caching)…"
curl -sS --location --compressed --fail --show-error \
  --etag-save "$ETAG_FILE" --etag-compare "$ETAG_FILE" \
  -o "$FEED_RAW" "$FEED_URL"

[ -s "$FEED_RAW" ] || { echo "ERROR: feed file is empty ($FEED_RAW)"; exit 1; }

echo "==> Parsing feed → IPv4(/CIDR)…"
# strip comments/CRLF, extract IPv4 or IPv4/CIDR anywhere on the line, de-dupe, cap
LC_ALL=C sed -E 's/#.*$//' "$FEED_RAW" | tr -d '\r' \
  | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?' \
  | sort -u | head -n "$MAX_ENTRIES" > "$NEW_LIST"

NEW_COUNT=$(wc -l < "$NEW_LIST" | tr -d ' ')
[ "$NEW_COUNT" -gt 0 ] || { echo "ERROR: no IPs parsed from feed"; exit 1; }
echo "==> Parsed $NEW_COUNT entries from feed."

echo "==> Reading current group from Mongo…"
"$MONGOSH_BIN" --quiet "$MONGO_URI" --eval '
const d=db.firewallgroup.findOne(
  { _id:ObjectId("'"$GROUP_ID"'") },
  { group_members:1 }
) || { group_members:[] };
print((d.group_members||[]).join("\n"));
' | sort -u > "$CURRENT_TMP"

echo "==> Computing deltas…"
# toAdd = in NEW but not CURRENT ; toRemove = in CURRENT but not NEW
comm -13 "$CURRENT_TMP" "$NEW_LIST" > "$TOADD" || true
comm -23 "$CURRENT_TMP" "$NEW_LIST" > "$TOREM" || true
ADD_N=$(wc -l < "$TOADD" | tr -d ' ')
REM_N=$(wc -l < "$TOREM" | tr -d ' ')
echo "==> Delta summary: add=$ADD_N, remove=$REM_N, desired_total=$NEW_COUNT"
echo "==> Sample add (up to 3):"; head -n 3 "$TOADD" || true
echo "==> Sample remove (up to 3):"; head -n 3 "$TOREM" || true

apply_batch () {
  local mode="$1" file="$2" n total=0
  n=$(wc -l < "$file" | tr -d ' ')
  [ "$n" -gt 0 ] || { echo "    (no $mode)"; return 0; }

  echo "==> Applying $mode in batches of $BATCH_SIZE…"
  local part tmpdir js_arr
  tmpdir="$(mktemp -d)"
  split -l "$BATCH_SIZE" "$file" "$tmpdir/part_"

  for part in "$tmpdir"/part_*; do
    # build compact JSON array for this batch
    js_arr=$(awk '{printf "\"%s\",",$0}' "$part" | sed 's/,$//')
    if [ "$mode" = "adds" ]; then
      # addToSet with $each (dedupe handled by Mongo)
      "$MONGOSH_BIN" --quiet "$MONGO_URI" --eval '
db.firewallgroup.updateOne(
  { _id: ObjectId("'"$GROUP_ID"'") },
  { $addToSet: { group_members: { $each: ['"$js_arr"'] } } }
);
' >/dev/null
    else
      # $pull with $in
      "$MONGOSH_BIN" --quiet "$MONGO_URI" --eval '
db.firewallgroup.updateOne(
  { _id: ObjectId("'"$GROUP_ID"'") },
  { $pull: { group_members: { $in: ['"$js_arr"'] } } }
);
' >/dev/null
    fi
    total=$(( total + $(wc -l < "$part") ))
  done
  rm -rf "$tmpdir"
  echo "    $mode applied: $total"
}

[ "$ADD_N" -gt 0 ] && apply_batch "adds" "$TOADD"
[ "$REM_N" -gt 0 ] && apply_batch "removes" "$TOREM"

echo "==> Reading back final count from Mongo…"
"$MONGOSH_BIN" --quiet "$MONGO_URI" --eval '
const d=db.firewallgroup.findOne(
  { _id:ObjectId("'"$GROUP_ID"'") },
  { group_members:1, name:1 }
) || { group_members:[], name:"unknown" };
printjson({ group:d.name, final_count:(d.group_members||[]).length });
'

echo "==> Done."
