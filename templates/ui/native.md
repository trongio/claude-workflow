## UI kit rules: no web UI (API, CLI, device or native client)

This project ships no browser UI of its own. The UI/UX standards still apply to every surface a person reads:

### API responses and errors
- Every error body is `{ "error": { "key": "...", "params": {...} } }` with a stable machine key, documented in the API reference with what the caller should do. Status codes are exact (400 malformed, 401 unauthenticated, 403 refused, 404 not found or not yours, 409 conflict, 422 invalid, 429 slow down). [guard-test]
- A refused write says why (the key) and changes nothing; retrying a refused write with the same idempotency key returns the same answer. [guard-test]
- Pending is a distinct state: an accepted async command returns 202 with a status resource, never 200 that pretends it is done. [review]
- Timestamps are RFC 3339 with an explicit offset; money is integer minor units with a currency code. [review]

### CLI output
- Default output is short and human: a table or a few lines, details in a file whose path is printed. `--json` gives the machine form. [review]
- Exit codes: 0 success, 1 failure, 2 usage error. Errors go to stderr, name the problem and the fix. [review]
- Colours only when stdout is a TTY and `NO_COLOR` is unset; never colour as the only signal. [review]
- User-facing strings are message keys when the CLI is localized. [review]

### Devices and native clients
- The device is the source of truth for life-safety behaviour (fail-safe egress, interlocks); the software never gates it. [review]
- "Never connected", "connected and quiet" and "offline since <time>" are three different states in every status the API reports. [guard-test]
- A native or device client's UI follows the platform's human interface guidelines; tap targets at least 44 pt. [review]
