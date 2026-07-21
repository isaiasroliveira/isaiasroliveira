#!/usr/bin/env bash
# Regenerates the language panel in README.md between the LANGS markers.
# Covers every repository the authenticated user can read — public, private,
# owned and organization — which the stock "top languages" widget cannot do.
#
# Requires: gh (authenticated with repo + read:org), jq
set -euo pipefail

if [[ -n "${CI:-}" && -z "${GH_TOKEN:-}" ]]; then
  echo "GH_TOKEN is empty — set the LANGS_TOKEN secret to a classic PAT with 'repo' + 'read:org'." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README="$ROOT/README.md"
RAW="$(mktemp)"
PANEL="$(mktemp)"
trap 'rm -f "$RAW" "$PANEL"' EXIT

gh api graphql --paginate --slurp -f query='
query($cursor: String) {
  viewer {
    repositories(
      first: 100
      after: $cursor
      affiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER]
      ownerAffiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER]
    ) {
      pageInfo { hasNextPage endCursor }
      nodes {
        nameWithOwner
        isPrivate
        isFork
        languages(first: 25, orderBy: {field: SIZE, direction: DESC}) {
          edges { size node { name } }
        }
      }
    }
  }
}' > "$RAW"

# Normalized share: every repo contributes equally, so one vendor-heavy bundle
# cannot hijack the panel. Raw byte totals are kept in the collapsible section.
jq -r '
  [.[].data.viewer.repositories.nodes[]] as $all
  | [$all[] | select(.isFork | not)] as $own
  | [$own[] | select(.languages.edges | length > 0)] as $coded
  | ($coded | length) as $n
  | [ $coded[]
      | (.languages.edges | map(.size) | add) as $total
      | .languages.edges[]
      | {name: .node.name, weight: (.size / $total), size: .size}
    ]
  | group_by(.name)
  | map({
      name: .[0].name,
      repos: length,
      share: ((map(.weight) | add) / $n * 1000 | round / 10),
      bytes: (map(.size) | add)
    })
  | sort_by(-.share) as $langs
  | ($langs | map(.bytes) | add) as $totalBytes
  | "| Language | Share | | Repos |",
    "|---|---:|---|---:|",
    ( $langs[]
      | (.share / 100 * 48 | round) as $filled
      | "| **\(.name)** | `\(if .share < 0.1 then "<0.1" else .share end)%` | `"
        + ("█" * $filled) + ("░" * (48 - $filled))
        + "` | \(.repos) |"
    ),
    "",
    "<details>",
    "<summary>By raw code volume (bytes)</summary>",
    "",
    "| Language | Bytes | Share |",
    "|---|---:|---:|",
    ( $langs
      | sort_by(-.bytes)[]
      | (.bytes / $totalBytes * 1000 | round / 10) as $pct
      | "| \(.name) | \(if .bytes > 1048576 then "\((.bytes / 1048576 * 10 | round) / 10) MB" elif .bytes > 1024 then "\((.bytes / 1024 | round)) KB" else "\(.bytes) B" end) | \(if $pct < 0.1 then "<0.1" else $pct end)% |"
    ),
    "",
    "</details>",
    "",
    ( ([$all[] | select(.isFork)] | length) as $forks
      | "<sub>Based on **\($all | length) repositories** — \([$all[] | select(.isPrivate)] | length) private, "
      + "\($forks) fork\(if $forks == 1 then "" else "s" end) excluded. "
      + "Primary metric: average share of each language per repository, so a single "
      + "vendor-heavy bundle cannot hijack the panel.</sub>"
    )
' "$RAW" > "$PANEL"

python3 - "$README" "$PANEL" <<'PY'
import pathlib, sys

readme_path, panel_path = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
start, end = "<!-- LANGS:START -->", "<!-- LANGS:END -->"

readme = readme_path.read_text(encoding="utf-8")
panel = panel_path.read_text(encoding="utf-8").strip()

head, _, rest = readme.partition(start)
_, _, tail = rest.partition(end)
if not _ and end not in rest:
    sys.exit(f"markers {start} / {end} not found in {readme_path}")

readme_path.write_text(f"{head}{start}\n\n{panel}\n\n{end}{tail}", encoding="utf-8")
PY

echo "Language panel updated in $README"
