# Catalog boundary benchmark

Run with:

```shell
MIX_ENV=dev mix run bench/catalog.exs
```

Local comparison on 2026-07-16, using the packaged 168-provider/5,988-model
snapshot and the same Erlang/Elixir installation for both revisions:

| Operation | Before (`ce04c14`) | Catalog boundary | Change |
| --- | ---: | ---: | ---: |
| Cold load | 1,027,620 µs | 895,195 µs | -12.9% |
| No-op reload | 1,022,509 µs | 909,781 µs | -11.0% |
| Warm direct lookup | 19.73 µs | 0.17 µs | -99.1% |

These are directional local measurements, not release guarantees. The warm
lookup difference reflects replacing provider scanning with immutable lookup
indexes. Re-run the script when the snapshot or runtime changes materially.

## Regression policy

The normal test suite checks behavior without a wall-clock limit. A fresh BEAM
VM must resolve a packaged string provider on its first query. A separate test
explicitly preloads the catalog and verifies that the next query does not
change the catalog epoch.

Use this benchmark for load-time measurements. Measure VM boot separately when
you compare total startup-to-first-lookup time. If load time needs a numeric CI
limit, run it on a dedicated performance runner and compare several samples
with a stored baseline. Do not use an absolute millisecond assertion in the
normal test suite.
