# Python / FastAPI mint proxy

Requires Python 3.11+.

## Run

```
pip install -r requirements.txt
SK_KEY=sk_test_... uvicorn server:app --host 0.0.0.0 --port 8787
```

Then point the Flutter SDK at `http://localhost:8787`:

```dart
final rest = TwaiApiRestClient(
  baseUrl: Uri.parse('http://localhost:8787'),
  credentials: const AnonymousCredentials(),
);
```

## Env

| Var              | Default                                                          |
| ---------------- | ---------------------------------------------------------------- |
| `SK_KEY`         | (required)                                                       |
| `UPSTREAM`       | staging twai-api URL                                             |
| `ALLOWED_ORIGIN` | `*` (tighten in prod)                                            |

## Mount into an existing FastAPI app

The four routes in `server.py` are standard FastAPI decorators — copy
them into your existing router with a prefix:

```python
from fastapi import APIRouter
router = APIRouter(prefix="/twai")
# paste the @app.post / @app.delete handlers here, s/@app./@router./g
app.include_router(router)
```

Then the SDK points at `https://yourapp.com/twai` (the SDK's
`TwaiApiRestClient` normalizes the trailing slash and preserves the
`/twai` prefix on all four endpoints).
