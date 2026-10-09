LLMDB.Test.GitHistoryFixture.clear_environment()

{:ok, _snapshot} = LLMDB.load()

ExUnit.start(capture_log: true, exclude: [:external])
