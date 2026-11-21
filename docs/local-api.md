# Local API

Read-only HTTP API for widgets and scripts. Off by default, enable it in Settings.

- Listens only on `127.0.0.1`, fixed port `9095`.
- Accepts `GET` (and `POST /v1/browser` for the companion browser extension). The `Host` header must be exactly `127.0.0.1:9095` or `localhost:9095`, otherwise the request is rejected with `400`.
- Responses are sent with `Cache-Control: no-store` and no CORS headers, so web pages from other origins cannot read them.
- While it is on, any program on the same device can read your activity. On Android a persistent notification keeps the service alive.

## OBS widget

Add a Browser Source with `http://127.0.0.1:9095/widget`.

| Parameter | Default | Meaning |
|---|---|---|
| `days` | `1` | Period, 1-90 days |
| `limit` | `5` | Apps shown, 1-10 |
| `metric` | `focused` | `focused`, `open`, `minimized`, `background`, `all` |
| `accent` | blue | Hex colour without `#` (up to 6 digits) |
| `lang` | browser language | `ru`, anything else is English |
| `bg` | card | `none` for a transparent background |

Example: `http://127.0.0.1:9095/widget?days=7&limit=8&accent=ff8a3d&bg=none`

## Endpoints

All responses are JSON. Durations are milliseconds, days are local `YYYY-MM-DD`.

### `GET /v1/current`

`{"uptime_ms": ..., "apps": [...]}`. Each app: `app`, `running`, `state` (`focused`, `open`, `minimized`, `background`), `focused_ms`, `open_ms`, `minimized_ms`, `background_ms`. Counters are since the core started.

### `GET /v1/summary?days=7&metric=focused`

Totals for the period: `from`, `to`, `days`, `apps_count`, `focused_ms`, `open_ms`, `minimized_ms`, `background_ms`, `total_ms`, `by_day[]` (same counters per day) and `top[]` (5 apps ranked by `metric`).
`days` is 1-90, default 7. `/v1/stats` is an alias.

### `GET /v1/apps/top?days=1&limit=5&metric=focused`

`{"from", "to", "days", "metric", "apps": [...]}`. Each app has `app`, `name` and the five counters above. Apps with a zero value for the chosen `metric` are omitted.
`days` is 1-90, default 1. `limit` is 1-50, default 5.

### `GET /v1/sessions?hours=24&limit=100`

`{"hours": ..., "sessions": [...]}`. Each session: `app`, `name`, `state`, `start`, `stop` (Unix seconds).
`hours` is 1-2160, default 24. `limit` is 1-500, default 100.

### `POST /v1/browser`

Accepts JSON `{"browser": "chrome", "domain": "github.com", "ms": 10000}` and accumulates active domain time for the current day.

### `GET /v1/browser/top?days=1&limit=10`

`{"from", "to", "days", "domains": [{"browser", "domain", "ms"}]}`. Top domains recorded by the companion browser extension.

## Rules

- Non-numeric parameters fall back to the default, out-of-range numbers are clamped.
- An unknown `metric` is treated as `focused`.
- Unknown paths return `404` with `{"error":"not found"}`.

## Example

```
curl "http://127.0.0.1:9095/v1/apps/top?days=7&limit=3"
```
