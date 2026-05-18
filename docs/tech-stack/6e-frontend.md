# Phase 6.E — Frontend Stack

> **Status:** Locked
> **Phase:** 6.E

## Decisions

| Concern | Decision |
|---|---|
| Build tool | Vite (latest stable at Phase 7 kickoff) |
| Framework | React 19 |
| Language | TypeScript 5.6+ strict (+ `noUncheckedIndexedAccess`) |
| Framework choice | React + Vite static dist (not Next.js) |
| Deploy | Cloudflare Pages (static) |
| Project structure | Module-per-feature, parallel to backend |
| Router | **TanStack Router** (type-safe) |
| UI library | **Mantine v8** |
| Mantine packages | core, hooks, notifications, dates, modals, spotlight |
| `@mantine/form` | Not used |
| Form library | React Hook Form + Zod |
| Server state | TanStack Query |
| UI state | Zustand |
| POS cart | Zustand + localStorage persist (until DRAFT created server-side) |
| Server/UI state mixing | Forbidden |
| HTTP client | **ky** |
| Auth interceptor | ky `hooks.beforeRequest` + refresh on 401 |
| Idempotency key | uuid per mutation, retried unchanged |
| Error handling | `ApiException` class + TanStack Query onError |
| i18n | react-i18next, Turkish first, English v1.1+ |
| Money math | **Dinero.js v2 stable** |
| Money display | Intl.NumberFormat |
| Number input | Mantine NumberInput, `thousandSeparator='.'`, `decimalSeparator=','` |
| Date library | date-fns + date-fns-tz |
| Date input | Mantine DatePickerInput + dayjs Turkish locale |
| Timezone | Format in store timezone, not browser TZ |
| Barcode scanner | `useBarcodeScanner` hook, 100ms keystroke window |
| Scanner scope | Route-scoped to `/pos` (not global) |
| Keyboard shortcuts | Mantine `useHotkeys`, F1-F12 POS bindings |
| Optimistic UI | Reversible operations only; not Sale.complete |
| Bundle splitting | Manual chunks: mantine, query, forms, dates, money |
| Route splitting | Lazy load by route |
| Test runner | Vitest |
| Component testing | React Testing Library |
| API mocking | MSW |
| E2E | 3-5 Playwright smoke tests (MVP) |
| Coverage target | 60% overall, 80% pos/auth |

## Why TanStack Router

- Type-safe URL params and search params (Zod-validated)
- Loader pattern integrates natively with TanStack Query
- POS uses heavy search-param filters (date range, store, status)
- Type safety on URL contracts reduces production bug class

## Why ky over axios

- ~7KB vs axios ~30KB
- Native fetch wrapper, modern
- Hooks pattern (beforeRequest, beforeRetry, afterResponse)
- Built-in retry with backoff

## Why Dinero.js v2

- Native Money type semantics (vs decimal.js generic)
- Currency-aware arithmetic
- 2.0.0 stable since March 2026

## Project structure

```
frontend/
├── src/
│   ├── app/                  ← App.tsx, router, providers
│   ├── modules/              ← parallel to backend modules
│   │   ├── auth/
│   │   ├── pos/              ← POS sale screen (full-screen, no AppShell)
│   │   ├── catalog/
│   │   ├── inventory/
│   │   ├── customers/
│   │   ├── suppliers/
│   │   ├── purchasing/
│   │   ├── financial/
│   │   ├── cashregister/
│   │   ├── reports/
│   │   └── settings/
│   ├── shared/
│   │   ├── api/              ← ky client, interceptors, types
│   │   ├── ui/               ← shared components, hooks
│   │   ├── i18n/             ← tr.json, en.json
│   │   ├── utils/            ← money.ts, date.ts, barcode.ts
│   │   └── types/
│   └── main.tsx
└── index.html
```

## POS-specific patterns

### Barcode scanner hook

```typescript
export function useBarcodeScanner({ onScan, minLength = 4, timeoutMs = 100 }) {
  const bufferRef = useRef('');
  const lastKeystrokeRef = useRef(0);

  useEffect(() => {
    function handleKeydown(e: KeyboardEvent) {
      const now = Date.now();
      const elapsed = now - lastKeystrokeRef.current;
      if (elapsed > timeoutMs) bufferRef.current = '';
      lastKeystrokeRef.current = now;

      if (e.key === 'Enter') {
        if (bufferRef.current.length >= minLength) {
          onScan(bufferRef.current);
          e.preventDefault();
        }
        bufferRef.current = '';
        return;
      }
      if (e.key.length === 1) bufferRef.current += e.key;
    }
    window.addEventListener('keydown', handleKeydown);
    return () => window.removeEventListener('keydown', handleKeydown);
  }, [onScan, minLength, timeoutMs]);
}
```

Fast keystrokes (<100ms apart) = scanner, slow = human typing.

### Keyboard shortcuts

```typescript
useHotkeys([
  ['F1', () => productSearchModal.open()],
  ['F2', () => customerSelectModal.open()],
  ['F3', () => discountModal.open()],
  ['F4', () => holdSale()],
  ['F9', () => printDuplicate()],
  ['F12', () => completeSale()],
  ['Escape', () => clearCart()],
]);
```

### Optimistic UI rules

| Action | Optimistic? | Reason |
|---|---|---|
| Add item to cart | Yes | Cheap to roll back, UX critical |
| Remove item | Yes | Reversible |
| Apply discount | Yes | Reversible |
| Change customer | Yes | Reversible |
| **Sale.complete** | **No** | Atomic, money + stock at stake |
| **Payment process** | **No** | External terminal involved |
| **Return.complete** | **No** | Stock + money side effect |

## Money handling (Dinero.js)

```typescript
import { dinero, add, multiply, toDecimal } from 'dinero.js';
import { TRY } from '@dinero.js/currencies';

const price = dinero({ amount: 12999, currency: TRY, scale: 2 });
const total = multiply(price, 3);
const display = formatMoney(toDecimal(total), 'TRY');  // "₺389,97"
```

Display only: `Intl.NumberFormat('tr-TR', { style: 'currency', currency: 'TRY' })`.

## API client setup

```typescript
export const api = ky.create({
  prefixUrl: import.meta.env.VITE_API_BASE_URL,
  timeout: 30_000,
  retry: { limit: 2, methods: ['get'], statusCodes: [408, 502, 503, 504] },
  hooks: {
    beforeRequest: [(request) => {
      const token = useAuthStore.getState().accessToken;
      if (token) request.headers.set('Authorization', `Bearer ${token}`);
    }],
    beforeRetry: [async ({ request }) => {
      if (request.headers.get('X-Auth-Retry') === 'true') return;
      await tryRefreshToken();
      request.headers.set('X-Auth-Retry', 'true');
      request.headers.set('Authorization', `Bearer ${useAuthStore.getState().accessToken}`);
    }],
    afterResponse: [(_req, _opts, res) => {
      if (res.status === 401) {
        useAuthStore.getState().logout();
        window.location.href = '/login';
      }
    }],
  },
});
```

## TypeScript / Zod / OpenAPI

- TypeScript types auto-generated from backend OpenAPI: `openapi-typescript`
- Zod schemas hand-written (for validation rules)
- Schema-drift detected in CI: `openapi-typescript ... && git diff --exit-code`
- v1.1+: `openapi-zod-client` to auto-generate Zod from OpenAPI

## Dependencies (selected)

```json
{
  "dependencies": {
    "react": "^19.x",
    "react-dom": "^19.x",
    "@mantine/core": "^8.x",
    "@mantine/hooks": "^8.x",
    "@mantine/notifications": "^8.x",
    "@mantine/dates": "^8.x",
    "@mantine/modals": "^8.x",
    "@mantine/spotlight": "^8.x",
    "@tanstack/react-router": "^1.x",
    "@tanstack/react-query": "^5.x",
    "zustand": "^5.x",
    "react-hook-form": "^7.x",
    "@hookform/resolvers": "^3.x",
    "zod": "^3.x",
    "ky": "^1.x",
    "dinero.js": "^2.x",
    "@dinero.js/currencies": "^2.x",
    "date-fns": "^4.x",
    "date-fns-tz": "^3.x",
    "dayjs": "^1.x",
    "react-i18next": "^15.x",
    "i18next": "^23.x",
    "@sentry/react": "^8.x"
  },
  "devDependencies": {
    "@vitejs/plugin-react": "latest",
    "vite": "latest stable",
    "typescript": "^5.6",
    "vitest": "^2.x",
    "@testing-library/react": "^16.x",
    "msw": "^2.x",
    "openapi-typescript": "^7.x",
    "@playwright/test": "^1.x"
  }
}
```

Final versions resolved at Phase 7 kickoff.
