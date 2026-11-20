# Local API

Read-only HTTP API for widgets and scripts. Off by default; enable it in Settings. It listens only on `127.0.0.1:9095`, accepts only `GET`, and rejects requests whose `Host` header is not local.

Any program on the device can read the data while it is on. On Android a persistent notification keeps the service alive.

## OBS widget

Add a Browser Source with `http://127.0.0.1:9095/widget`.

| Parameter | Default | Meaning |
|---|---|---|
| `days` | `1` | Period, 1-90 days |
| `limit` | `5` | Apps shown, 1-10 |
| `metric` | `focused` | `focused`, `open`, `minimized`, `background`, `all` |
| `accent` | blue | Hex colour without `#` |
| `lang` | browser | `ru` or `en` |
| `bg` | card | `none` for a transparent background |

Example: `http://127.0.0.1:9095/widget?days=7&limit=8&accent=ff8a3d&bg=none`

## Endpoints

All return JSON. Durations are in milliseconds.

### `GET /v1/current`

Live state of tracked apps: `uptime_ms` and `apps[]` with `app`, `running`, `state`, `focused_ms`, `open_ms`, `minimized_ms`, `background_ms`.

### `GET /v1/summary?days=7&metric=focused`

Totals for the period: `from`, `to`, `days`, `apps_count`, the four `*_ms` counters and `total_ms`, `by_day[]`, and `top[]` (5 apps). `days` is 1-90. `/v1/stats` is an alias.

### `GET /v1/apps/top?days=1&limit=5&metric=focused`

Apps ranked by `metric`. `limit` is 1-50. Each item has `app`, `name` and the same counters.

### `GET /v1/sessions?hours=24&limit=100`

Recent sessions: `app`, `name`, `state`, `start`, `stop` (Unix seconds). `hours` is 1-2160, `limit` is 1-500.

Invalid or out-of-range numbers fall back to the default or are clamped. Unknown paths return `404`.

## Example

```
curl http://127.0.0.1:9095/v1/apps/top?days=7&limit=3
```
