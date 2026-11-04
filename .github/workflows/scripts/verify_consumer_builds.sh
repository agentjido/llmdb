#!/usr/bin/env bash
set -euo pipefail

project_root=$(git rev-parse --show-toplevel)
source_commit=$(git rev-parse HEAD)
qa_root=$(mktemp -d "${TMPDIR:-/tmp}/llmdb-consumers.XXXXXX")
trap 'rm -rf "$qa_root"' EXIT

write_consumer() {
  local directory=$1
  local app_name=$2
  local dependency=$3

  mkdir -p "$directory/config" "$directory/lib"

  cat >"$directory/mix.exs" <<EOF
defmodule LLMDBConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :$app_name,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [$dependency]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
EOF

  cat >"$directory/config/config.exs" <<'EOF'
import Config

config :llm_db,
  compile_embed: true,
  integrity_policy: :strict
EOF

  cat >"$directory/lib/consumer_check.ex" <<'EOF'
defmodule LLMDBConsumer.Check do
  def run! do
    {:ok, model} = LLMDB.model("openai:gpt-4o")
    true = model.provider == :openai
    {:ok, albert} = LLMDB.model("albert:gpt-oss-120b")
    true = albert.provider == :albert
    true = is_binary(LLMDB.snapshot().meta.source_snapshot_id)
    :ok
  end
end
EOF
}

verify_consumer() {
  local directory=$1
  (
    cd "$directory"
    MIX_ENV=prod mix deps.get
    MIX_ENV=prod mix deps.compile
    MIX_ENV=prod mix run -e 'LLMDBConsumer.Check.run!()'
  )
}

path_consumer="$qa_root/path-consumer"
write_consumer "$path_consumer" "llmdb_path_consumer" "{:llm_db, path: \"$project_root\"}"
verify_consumer "$path_consumer"

git_consumer="$qa_root/git-consumer"
git_source="$qa_root/git-source"
mkdir -p "$git_source"
git archive "$source_commit" | tar -x -C "$git_source"
git -C "$git_source" init --quiet --initial-branch=main
git -C "$git_source" config user.email "ci@llmdb.local"
git -C "$git_source" config user.name "LLMDB CI"
git -C "$git_source" add --all
git -C "$git_source" commit --quiet -m "test: materialize checked-out source"
git_source_commit=$(git -C "$git_source" rev-parse HEAD)

write_consumer "$git_consumer" "llmdb_git_consumer" \
  "{:llm_db, git: \"file://$git_source\", ref: \"$git_source_commit\"}"
verify_consumer "$git_consumer"

hex_archive="$qa_root/llm_db.tar"
hex_outer="$qa_root/hex-outer"
hex_package="$qa_root/hex-package"
mkdir -p "$hex_outer" "$hex_package"
(
  cd "$project_root"
  mix hex.build --output "$hex_archive"
)
tar -xf "$hex_archive" -C "$hex_outer"
tar -xzf "$hex_outer/contents.tar.gz" -C "$hex_package"

source_snapshot_id=$(jq -r '.snapshot_id' "$project_root/priv/llm_db/snapshot.json")
hex_snapshot_id=$(jq -r '.snapshot_id' "$hex_package/priv/llm_db/snapshot.json")
npm_export="$qa_root/npm-export"
(
  cd "$project_root"
  mix llm_db.npm.export --output "$npm_export"
)
npm_snapshot_id=$(jq -r '.snapshot_id' "$npm_export/manifest.json")

if [[ "$source_snapshot_id" != "$hex_snapshot_id" || "$source_snapshot_id" != "$npm_snapshot_id" ]]; then
  echo "Hex and NPM snapshot identities do not match the verified source snapshot" >&2
  exit 1
fi

hex_consumer="$qa_root/hex-consumer"
write_consumer "$hex_consumer" "llmdb_hex_consumer" "{:llm_db, path: \"$hex_package\"}"
verify_consumer "$hex_consumer"
