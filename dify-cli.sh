#!/usr/bin/env bash
set -euo pipefail

# ===== config =====
# resolve script real path (follow symlinks)
SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
while [ -L "$SCRIPT_PATH" ]; do
  LINK_TARGET="$(readlink "$SCRIPT_PATH")"
  case "$LINK_TARGET" in
    /*) SCRIPT_PATH="$LINK_TARGET";;
    *) SCRIPT_PATH="$(dirname "$SCRIPT_PATH")/$LINK_TARGET";;
  esac
done
ROOT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
# .env をスクリプト配置 or カレントディレクトリから読込
ENV_DIR="$ROOT_DIR"
if [ -f "$ROOT_DIR/.env" ]; then
  set -a && . "$ROOT_DIR/.env" && set +a
elif [ -f "./.env" ]; then
  set -a && . "./.env" && set +a
  ENV_DIR="$(pwd)"
fi

: "${CONSOLE_API_BASE:?Set CONSOLE_API_BASE in .env}"
: "${EMAIL:?Set EMAIL in .env}"
: "${PASSWORD:?Set PASSWORD in .env}"
OUT_DIR="${OUT_DIR:-$ENV_DIR/dsl}"
TOKEN_FILE="${TOKEN_FILE:-$ENV_DIR/.dify_token}"

mkdir -p "$OUT_DIR"

# ===== helpers =====
jqr () { jq -r "$@" ; }
uri () { jq -rn --arg v "$1" '$v|@uri'; }
slugify () { tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'; }

# base64url decoder (portable for macOS/Linux)
b64url_decode () {
  local data="$1"
  data="$(printf '%s' "$data" | tr '_-' '/+')"
  case $(( ${#data} % 4 )) in
    2) data="${data}==";;
    3) data="${data}=";;
    *) :;;
  esac
  printf '%s' "$data" | base64 -d 2>/dev/null || printf '%s' "$data" | base64 -D 2>/dev/null
}

have_token () { [ -s "$TOKEN_FILE" ]; }
get_token () { cat "$TOKEN_FILE"; }

save_token () { printf '%s' "$1" > "$TOKEN_FILE"; }

auth_header () {
  local token="${1:-$(get_token)}"
  printf "Authorization: Bearer %s" "$token"
}

die () { echo "Error: $*" >&2; exit 1; }

# help helpers
is_help_flag () {
  case "${1:-}" in
    -h|--help|help) return 0;;
    *) return 1;;
  esac
}

sub_help () {
  case "$1" in
    login) echo "Usage: dify login";;
    me) echo "Usage: dify me";;
    logout) echo "Usage: dify logout";;
    apps) echo "Usage: dify apps [page] [limit]";;
    app) echo "Usage: dify app <APP_ID>";;
    export) echo "Usage: dify export <APP_ID> [include_secret=false]";;
    import) echo "Usage: dify import <DSL_YAML_FILE>";;
    publish) echo "Usage: dify publish <WORKFLOW_APP_ID> [marked_name] [marked_comment]";;
    publish-info) echo "Usage: dify publish-info <WORKFLOW_APP_ID>";;
    logs-workflow) echo "Usage: dify logs-workflow <APP_ID> <AFTER_ISO> <BEFORE_ISO> [page] [limit]";;
    logs-chat) echo "Usage: dify logs-chat <APP_ID> <START> <END> [page] [limit] [sort_by]";;
    tool-get) echo "Usage: dify tool-get <WORKFLOW_APP_ID>";;
    tool-create) echo "Usage: dify tool-create <JSON_FILE>";;
    tool-update) echo "Usage: dify tool-update <JSON_FILE>";;
    tool-refs-in-app) echo "Usage: dify tool-refs-in-app <PARENT_APP_ID>";;
    export-tools-of-app) echo "Usage: dify export-tools-of-app <PARENT_APP_ID> [include_secret=false]";;
    find-apps-with-workflow-tools) echo "Usage: dify find-apps-with-workflow-tools";;
    export-all-workflows) echo "Usage: dify export-all-workflows [include_secret=false]";;
    deps-generate) echo "Usage: dify deps-generate [OUT_PATH]";;
    *) echo "Usage: dify --help";;
  esac
}

# ===== commands =====

cmd_login () {
  echo ">> Logging in to $CONSOLE_API_BASE ..."
  local token
  token="$(
    curl -fsS -X POST "$CONSOLE_API_BASE/login" \
      -H 'Content-Type: application/json' \
      -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" \
    | jq -r '(.data.access_token // .access_token // .token) // empty'
  )"
  [ -n "$token" ] || die "failed to obtain access_token"
  save_token "$token"
  echo "OK. token saved to $TOKEN_FILE"
}

ensure_login () { have_token || cmd_login; }

cmd_me () {
  ensure_login
  local token payload_b64 payload_json apps_total profile_resp ws_resp code body
  token="$(get_token)"
  payload_b64="$(printf '%s' "$token" | cut -d '.' -f 2)"
  if [ -z "$payload_b64" ]; then
    die "invalid token format"
  fi
  payload_json="$(b64url_decode "$payload_b64" 2>/dev/null | jq -c . 2>/dev/null || true)"
  if [ -z "$payload_json" ]; then
    payload_json='null'
  fi
  # 1) account/profile
  profile_resp="$(curl -sS -w '\n%{http_code}' "$CONSOLE_API_BASE/account/profile" -H "$(auth_header)" 2>/dev/null || true)"
  body="$(printf '%s' "$profile_resp" | sed '$d')"
  code="$(printf '%s' "$profile_resp" | tail -n1)"
  case "$code" in
    200)
      jq -n --arg base "$CONSOLE_API_BASE" --argjson token_payload "$payload_json" \
        --argjson profile "$(printf '%s' "$body" | jq -c '.data // .')" \
        '{api_base:$base, auth_ok:true, source:"/account/profile", profile:$profile, token_payload:$token_payload}'
      return 0
      ;;
    401)
      die "unauthorized (token invalid or expired). run: dify login"
      ;;
  esac
  # 2) workspaces/current
  ws_resp="$(curl -sS -w '\n%{http_code}' "$CONSOLE_API_BASE/workspaces/current" -H "$(auth_header)" 2>/dev/null || true)"
  body="$(printf '%s' "$ws_resp" | sed '$d')"
  code="$(printf '%s' "$ws_resp" | tail -n1)"
  case "$code" in
    200)
      jq -n --arg base "$CONSOLE_API_BASE" --argjson token_payload "$payload_json" \
        --argjson workspace "$(printf '%s' "$body" | jq -c '.data // .')" \
        '{api_base:$base, auth_ok:true, source:"/workspaces/current", workspace:$workspace, token_payload:$token_payload}'
      return 0
      ;;
    401)
      die "unauthorized (token invalid or expired). run: dify login"
      ;;
  esac
  # 3) fallback: apps probe + token payloadのみ
  apps_total="$(curl -fsS "$CONSOLE_API_BASE/apps?page=1&limit=1" -H "$(auth_header)" 2>/dev/null | jq -r '.total // empty' 2>/dev/null || true)"
  jq -n \
    --arg base "$CONSOLE_API_BASE" \
    --arg total "${apps_total:-}" \
    --argjson payload "$payload_json" \
    '{api_base:$base, auth_ok:(($total|tonumber? // 0) > 0), apps_total:($total|tonumber? // null), token_payload:$payload}'
}

cmd_logout () {
  ensure_login
  curl -fsS "$CONSOLE_API_BASE/logout" -H "$(auth_header)" >/dev/null || true
  : >"$TOKEN_FILE"
  echo "OK. logged out and token cleared: $TOKEN_FILE"
}

cmd_apps () {
  ensure_login
  curl -fsS "$CONSOLE_API_BASE/apps?page=${1:-1}&limit=${2:-50}" -H "$(auth_header)" \
  | jq '{total, data: [.data[]|{id,name,mode:.mode}]}'
}

cmd_app () {
  ensure_login
  local app_id="${1:?usage: $0 app <APP_ID>}"
  curl -fsS "$CONSOLE_API_BASE/apps/$app_id" -H "$(auth_header)"
}

cmd_export () {
  ensure_login
  local app_id="${1:?usage: $0 export <APP_ID> [include_secret=false]}"
  local include="${2:-false}"

  # アプリ名→ファイル名
  local app_json app_name slug
  app_json="$(curl -fsS "$CONSOLE_API_BASE/apps/$app_id" -H "$(auth_header)")"
  app_name="$(echo "$app_json" | jq -r --arg fallback "$app_id" '.data.name // .name // $fallback')"
  slug="$(printf '%s' "$app_name" | slugify)"
  # 日本語等のみで slug が空になる場合は app_id を使う
  if [ -z "$slug" ]; then
    slug="$app_id"
  fi

  echo ">> Exporting DSL for $app_name ($app_id) include_secret=$include"
  local resp dsl
  resp="$(curl -fsS "$CONSOLE_API_BASE/apps/$app_id/export?include_secret=$include" -H "$(auth_header)")"

  # レスポンスのどちらかに入ってる（環境差異吸収）
  dsl="$(echo "$resp" | jq -r '.data // .dsl')"
  [ "$dsl" != "null" ] && [ -n "$dsl" ] || die "export response did not contain DSL"

  mkdir -p "$OUT_DIR/apps"
  local out="$OUT_DIR/apps/${slug}.yml"
  printf '%s\n' "$dsl" > "$out"
  echo "saved: $out"
}

cmd_import () {
  ensure_login
  local yaml_file="${1:?usage: $0 import <DSL_YAML_FILE>}"
  [ -f "$yaml_file" ] || die "not found: $yaml_file"
  echo ">> Importing $yaml_file"
  curl -fsS -X POST "$CONSOLE_API_BASE/apps/imports" \
    -H "$(auth_header)" -H 'Content-Type: application/json' \
    --data-binary @- <<JSON
{"mode":"yaml-content","yaml_content":$(jq -Rsa . < "$yaml_file")}
JSON
}

cmd_publish () {
  ensure_login
  local workflow_app_id="${1:?usage: $0 publish <WORKFLOW_APP_ID> [marked_name] [marked_comment] }"
  local name="${2:-}"
  local comment="${3:-}"
  curl -fsS -X POST "$CONSOLE_API_BASE/apps/$workflow_app_id/workflows/publish" \
    -H "$(auth_header)" -H 'Content-Type: application/json' \
    --data-raw "{\"marked_name\":\"$name\",\"marked_comment\":\"$comment\"}"
}

cmd_publish_info () {
  ensure_login
  local workflow_app_id="${1:?usage: $0 publish-info <WORKFLOW_APP_ID>}"
  curl -fsS "$CONSOLE_API_BASE/apps/$workflow_app_id/workflows/publish" -H "$(auth_header)"
}

cmd_logs_workflow () {
  ensure_login
  local app_id="${1:?usage: $0 logs-workflow <APP_ID> <AFTER_ISO> <BEFORE_ISO> [page] [limit]}"
  local after="$(uri "${2:?AFTER_ISO}")"
  local before="$(uri "${3:?BEFORE_ISO}")"
  local page="${4:-1}" limit="${5:-10}"
  local url="$CONSOLE_API_BASE/apps/$app_id/workflow-app-logs?page=$page&limit=$limit&created_at__after=$after&created_at__before=$before"
  curl -fsS "$url" -H "$(auth_header)"
}

cmd_logs_chat () {
  ensure_login
  local app_id="${1:?usage: $0 logs-chat <APP_ID> <START> <END> [page] [limit] [sort_by]}"
  local start="$(uri "${2:?START}")"
  local end="$(uri "${3:?END}")"
  local page="${4:-1}" limit="${5:-10}" sort="${6:--created_at}"
  local url="$CONSOLE_API_BASE/apps/$app_id/chat-conversations?page=$page&limit=$limit&start=$start&end=$end&sort_by=$(uri "$sort")&annotation_status=all"
  curl -fsS "$url" -H "$(auth_header)"
}

cmd_tool_get () {
  ensure_login
  local workflow_app_id="${1:?usage: $0 tool-get <WORKFLOW_APP_ID>}"
  curl -fsS "$CONSOLE_API_BASE/workspaces/current/tool-provider/workflow/get?workflow_app_id=$workflow_app_id" \
    -H "$(auth_header)"
}

cmd_tool_create () {
  ensure_login
  local json_file="${1:?usage: $0 tool-create <JSON_FILE>}"
  curl -fsS -X POST "$CONSOLE_API_BASE/workspaces/current/tool-provider/workflow/create" \
    -H "$(auth_header)" -H 'Content-Type: application/json' \
    --data-binary @"$json_file"
}

cmd_tool_update () {
  ensure_login
  local json_file="${1:?usage: $0 tool-update <JSON_FILE>}"
  curl -fsS -X POST "$CONSOLE_API_BASE/workspaces/current/tool-provider/workflow/update" \
    -H "$(auth_header)" -H 'Content-Type: application/json' \
    --data-binary @"$json_file"
}

# ===== parent-child (workflow tool relations) =====
cmd_tool_refs_in_app () {
  ensure_login
  local app_id="${1:?usage: $0 tool-refs-in-app <PARENT_APP_ID>}"
  curl -fsS "$CONSOLE_API_BASE/apps/$app_id/workflows/draft" -H "$(auth_header)" \
  | jq -cr '
    ((.graph.nodes // [])[]?)
    | select(.data.type=="tool" and (.data.provider_type=="workflow"))
    | {title: .data.title, tool_label: (.data.tool_label // .data.provider_name // .data.tool_name),
       workflow_tool_id: .data.provider_id}
  '
}

build_workflow_tool_index () {
  ensure_login
  local page=1 limit=50 out='[]'
  while :; do
    local resp total
    resp=$(curl -fsS "$CONSOLE_API_BASE/apps?page=$page&limit=$limit" -H "$(auth_header)")
    total=$(echo "$resp" | jq -r '.total // 0')
    echo "$resp" | jq -r '.data[] | select(.mode=="workflow") | .id' | while read -r wid; do
      local tool_json
      tool_json=$(curl -fsS "$CONSOLE_API_BASE/workspaces/current/tool-provider/workflow/get?workflow_app_id=$wid" -H "$(auth_header)" 2>/dev/null || true)
      echo "$tool_json" | jq -er '.workflow_tool_id' >/dev/null 2>&1 || continue
      echo "$tool_json" | jq -c '{workflow_tool_id, workflow_app_id}'
    done | jq -s 'unique_by(.workflow_tool_id)' >"$ROOT_DIR/.tool_index.tmp.json"

    out=$(jq -cn --argjson a "$out" --argjson b "$(cat "$ROOT_DIR/.tool_index.tmp.json")" '$a + $b | unique_by(.workflow_tool_id)')
    [ $((page*limit)) -ge "$total" ] && break
    page=$((page+1))
  done
  echo "$out"
}

cmd_export_tools_of_app () {
  ensure_login
  local parent_app_id="${1:?usage: $0 export-tools-of-app <PARENT_APP_ID> [include_secret=false]}"
  local include="${2:-false}"
  mkdir -p "$OUT_DIR/apps"

  echo ">> Collect tool nodes from parent app..."
  local refs_json
  refs_json="$(curl -fsS "$CONSOLE_API_BASE/apps/$parent_app_id/workflows/draft" -H "$(auth_header)" \
    | jq -c '[((.graph.nodes // [])[]?)
              | select(.data.type=="tool" and (.data.provider_type=="workflow"))
              | {workflow_tool_id: .data.provider_id,
                 tool_label: (.data.tool_label // .data.provider_name // .data.tool_name // "tool")}]')"

  if [ "$(echo "$refs_json" | jq 'length')" -eq 0 ]; then
    echo "No workflow tools found in parent app."
    return 0
  fi

  echo ">> Build workflow_tool_id -> workflow_app_id index..."
  local index_json
  index_json="$(build_workflow_tool_index)"

  echo "$refs_json" | jq -c '.[]' | while read -r ref; do
    local tid label aid slug resp dsl
    tid=$(echo "$ref" | jq -r '.workflow_tool_id')
    label=$(echo "$ref" | jq -r '.tool_label')
    aid=$(echo "$index_json" | jq -r --arg tid "$tid" '.[] | select(.workflow_tool_id==$tid) | .workflow_app_id' | head -n1)

    if [ -z "$aid" ] || [ "$aid" = "null" ]; then
      echo "!! skip (no mapping): $label ($tid)"
      continue
    fi

    slug="$(printf '%s' "$label" | slugify)"
    if [ -z "$slug" ]; then
      slug="$tid"
    fi

    echo ">> Exporting: $label  (tool_id=$tid, app_id=$aid)"
    resp="$(curl -fsS "$CONSOLE_API_BASE/apps/$aid/export?include_secret=$include" -H "$(auth_header)")"
    dsl="$(echo "$resp" | jq -r '.data // .dsl')"
    [ -n "$dsl" ] && [ "$dsl" != "null" ] || { echo "!! export failed for $aid"; continue; }
    printf '%s\n' "$dsl" > "$OUT_DIR/apps/${slug}.yml"
    echo "saved: $OUT_DIR/apps/${slug}.yml"
  done
}

cmd_find_apps_with_workflow_tools () {
  ensure_login
  local page=1 limit=50 any=0
  while :; do
    local resp total
    resp=$(curl -fsS "$CONSOLE_API_BASE/apps?page=$page&limit=$limit" -H "$(auth_header)")
    total=$(echo "$resp" | jq -r '.total // 0')
    echo "$resp" | jq -r '.data[] | select(.mode=="workflow") | .id' | while read -r wid; do
      curl -fsS "$CONSOLE_API_BASE/apps/$wid/workflows/draft" -H "$(auth_header)" \
        | jq -cr --arg id "$wid" '((.graph.nodes // [])[]?|select(.data.type=="tool" and (.data.provider_type=="workflow"))) as $n | {parent_app_id:$id, tool_label:($n.data.tool_label // $n.data.provider_name // $n.data.tool_name // "tool"), workflow_tool_id:$n.data.provider_id}'
    done
    [ $((page*limit)) -ge "$total" ] && break
    page=$((page+1))
  done
}

# Generate dependency index (parent workflow app -> child workflow apps via workflow tools)
cmd_deps_generate () {
  ensure_login
  local out="${1:-$ENV_DIR/dsl/deps.json}"
  mkdir -p "$(dirname "$out")"

  echo ">> Step1: build workflow_tool_id -> workflow_app_id index"
  local index_json
  index_json="$(build_workflow_tool_index)"

  echo ">> Step2: scan all apps and collect workflow tool edges"
  local page=1 limit=50 edges='[]' apps_meta='[]'
  while :; do
    local resp total
    resp=$(curl -fsS "$CONSOLE_API_BASE/apps?page=$page&limit=$limit" -H "$(auth_header)")
    total=$(echo "$resp" | jq -r '.total // 0')

    # merge apps meta (normalize to array before merging)
    apps_meta=$(jq -cn \
      --argjson a "$apps_meta" \
      --argjson b "$(echo "$resp" | jq -c '[.data[] | {id,name,mode}]')" \
      '$a + $b')

    # enumerate parents and extract tool edges
    echo "$resp" | jq -r '.data[].id' | while read -r aid; do
      local app_json app_name
      app_json="$(curl -fsS "$CONSOLE_API_BASE/apps/$aid/workflows/draft" -H "$(auth_header)" 2>/dev/null || true)"
      if [ -z "$app_json" ]; then continue; fi
      app_name="$(curl -fsS "$CONSOLE_API_BASE/apps/$aid" -H "$(auth_header)" | jq -r '.data.name // .name')"
      jq -r --arg pid "$aid" --arg pname "$app_name" --argjson idx "$index_json" '
        ((.graph.nodes // [])[]? 
         | select(.data.type=="tool" and (.data.provider_type=="workflow"))) as $n
        | {
            parent_app_id:   $pid,
            parent_app_name: $pname,
            node_title:      ($n.data.title // $n.data.tool_label // $n.data.provider_name // $n.data.tool_name),
            workflow_tool_id: $n.data.provider_id,
            child_workflow_app_id: ( [ $idx[] | select(.workflow_tool_id == $n.data.provider_id) | .workflow_app_id ] | (.[0] // null) )
          }' <<<"$app_json"
    done | jq -s '.' > "$ROOT_DIR/.deps.edges.tmp.json"

    edges=$(jq -cn --argjson a "$edges" --argjson b "$(cat "$ROOT_DIR/.deps.edges.tmp.json")" '$a + $b')
    [ $((page*limit)) -ge "$total" ] && break
    page=$((page+1))
  done

  # orphans: workflow apps exposed as tools but not referenced by any parent
  local orphans
  orphans=$(jq -cn --argjson idx "$index_json" --argjson e "$edges" '
    ([$e[] | .child_workflow_app_id] | map(select(.!=null)) | unique) as $used |
    ([$idx[] | .workflow_app_id] | unique) as $all |
    ($all - $used)
  ')

  jq -n \
    --arg now "$(date -u +%FT%TZ)" \
    --arg version "v1" \
    --argjson edges "$(echo "$edges" | jq 'unique')" \
    --argjson orphans "$orphans" \
    --argjson apps "$(echo "$apps_meta" | jq 'unique_by(.id)')" '
    {
      version: $version,
      generated_at: $now,
      edges: $edges,
      orphans: $orphans,
      apps: $apps
    }
  ' | tee "$out" >/dev/null

  echo "saved: $out"
}

# Export all workflow apps DSLs in the workspace
cmd_export_all_workflows () {
  ensure_login
  local include="${1:-false}"
  local page=1 limit=50
  mkdir -p "$OUT_DIR/apps"
  echo ">> Export all workflow apps (include_secret=$include)"
  while :; do
    local resp total
    resp=$(curl -fsS "$CONSOLE_API_BASE/apps?page=$page&limit=$limit" -H "$(auth_header)")
    total=$(echo "$resp" | jq -r '.total // 0')
    echo "$resp" | jq -cr '.data[] | select(.mode=="workflow") | {id,name}' | while read -r row; do
      local app_id app_name slug resp2 dsl out
      app_id=$(echo "$row" | jq -r '.id')
      app_name=$(echo "$row" | jq -r '.name')
      slug=$(printf '%s' "$app_name" | slugify)
      if [ -z "$slug" ]; then slug="$app_id"; fi
      echo ">> Exporting $app_name ($app_id)"
      resp2=$(curl -fsS "$CONSOLE_API_BASE/apps/$app_id/export?include_secret=$include" -H "$(auth_header)")
      dsl=$(echo "$resp2" | jq -r '.data // .dsl')
      [ -n "$dsl" ] && [ "$dsl" != "null" ] || { echo "!! export failed for $app_id"; continue; }
      out="$OUT_DIR/apps/${slug}.yml"
      # avoid overwrite when multiple apps slugify to the same name
      if [ -e "$out" ]; then
        out="$OUT_DIR/apps/${slug}-${app_id}.yml"
      fi
      printf '%s\n' "$dsl" > "$out"
      echo "saved: $out"
    done
    [ $((page*limit)) -ge "$total" ] && break
    page=$((page+1))
  done
}

cmd_help () {
  cat <<'USAGE'
Usage:
  dify login
  dify me
  dify logout
  dify apps [page] [limit]
  dify app <APP_ID>

  dify export <APP_ID> [include_secret=false]
  dify import <DSL_YAML_FILE>

  dify publish <WORKFLOW_APP_ID> [marked_name] [marked_comment]
  dify publish-info <WORKFLOW_APP_ID>

  dify logs-workflow <APP_ID> <AFTER_ISO> <BEFORE_ISO> [page] [limit]
    # AFTER_ISO/BEFORE_ISO e.g. 2025-06-04T11:00:00-04:00

  dify logs-chat <APP_ID> <START> <END> [page] [limit] [sort_by]
    # START/END e.g. "2025-06-19 00:00" "2025-06-26 23:59"

  dify tool-get <WORKFLOW_APP_ID>
  dify tool-create <JSON_FILE>
  dify tool-update <JSON_FILE>

  dify tool-refs-in-app <PARENT_APP_ID>
  dify export-tools-of-app <PARENT_APP_ID> [include_secret=false]
  dify find-apps-with-workflow-tools
  dify export-all-workflows [include_secret=false]
  dify deps-generate [OUT_PATH]

Storage layout:
  - DSL files centralized under: ./dsl/apps/*.yml
  - Dependency index: ./dsl/deps.json (optional; generated by deps commands)

Notes:
  - Authorization header: "Authorization: Bearer <token>"
  - Timestamps should include offset (e.g. 2025-06-04T11:00:00-04:00)
  - logs-workflow uses created_at__after / created_at__before
USAGE
}

# global help flags
if is_help_flag "${1:-}"; then
  cmd_help
  exit 0
fi

case "${1:-help}" in
  login) shift; if is_help_flag "${1:-}"; then sub_help login; exit 0; fi; cmd_login "$@";;
  me) shift; if is_help_flag "${1:-}"; then sub_help me; exit 0; fi; cmd_me "$@";;
  logout) shift; if is_help_flag "${1:-}"; then sub_help logout; exit 0; fi; cmd_logout "$@";;
  apps) shift; if is_help_flag "${1:-}"; then sub_help apps; exit 0; fi; cmd_apps "$@";;
  app) shift; if is_help_flag "${1:-}"; then sub_help app; exit 0; fi; cmd_app "$@";;
  export) shift; if is_help_flag "${1:-}"; then sub_help export; exit 0; fi; cmd_export "$@";;
  import) shift; if is_help_flag "${1:-}"; then sub_help import; exit 0; fi; cmd_import "$@";;
  publish) shift; if is_help_flag "${1:-}"; then sub_help publish; exit 0; fi; cmd_publish "$@";;
  publish-info) shift; if is_help_flag "${1:-}"; then sub_help publish-info; exit 0; fi; cmd_publish_info "$@";;
  logs-workflow) shift; if is_help_flag "${1:-}"; then sub_help logs-workflow; exit 0; fi; cmd_logs_workflow "$@";;
  logs-chat) shift; if is_help_flag "${1:-}"; then sub_help logs-chat; exit 0; fi; cmd_logs_chat "$@";;
  tool-get) shift; if is_help_flag "${1:-}"; then sub_help tool-get; exit 0; fi; cmd_tool_get "$@";;
  tool-create) shift; if is_help_flag "${1:-}"; then sub_help tool-create; exit 0; fi; cmd_tool_create "$@";;
  tool-update) shift; if is_help_flag "${1:-}"; then sub_help tool-update; exit 0; fi; cmd_tool_update "$@";;
  tool-refs-in-app) shift; if is_help_flag "${1:-}"; then sub_help tool-refs-in-app; exit 0; fi; cmd_tool_refs_in_app "$@";;
  export-tools-of-app) shift; if is_help_flag "${1:-}"; then sub_help export-tools-of-app; exit 0; fi; cmd_export_tools_of_app "$@";;
  find-apps-with-workflow-tools) shift; if is_help_flag "${1:-}"; then sub_help find-apps-with-workflow-tools; exit 0; fi; cmd_find_apps_with_workflow_tools "$@";;
  export-all-workflows) shift; if is_help_flag "${1:-}"; then sub_help export-all-workflows; exit 0; fi; cmd_export_all_workflows "$@";;
  deps-generate) shift; if is_help_flag "${1:-}"; then sub_help deps-generate; exit 0; fi; cmd_deps_generate "$@";;
  *) cmd_help;;
esac


