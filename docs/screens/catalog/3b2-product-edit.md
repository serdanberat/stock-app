# 3.B.2 — Product Create / Edit

> **Status:** Locked (Phase 3.B)
> **Routes:**
> - `/catalog/products/new` — Create
> - `/catalog/products/{id}/edit` — Edit
> - `/catalog/products/new?prefill_from_missing_request={req_id}` — From 3.B.6

## Purpose

Manage the Product aggregate (catalog identity). Master fields, taxonomy, VAT, single primary photo.

Does NOT define: variants (3.B.3), pricing (3.B.4), stock (Inventory).

## Aggregate ownership (explicit)

- **Writes** Product aggregate only
- Variants / pricing / stock NOT mutated here
- Hand-off to other aggregates via navigation buttons after save

## Reads

- `GET /catalog/products/{id}` — Full aggregate
- `GET /catalog/brands` — Dropdown
- `GET /catalog/categories` — Hierarchical tree
- `GET /catalog/seasons` — Dropdown
- `GET /catalog/vat-rates` — Allowed VAT rates
- `GET /catalog/missing-item-requests/{id}` — If prefilling

## Writes

| Endpoint | Purpose |
|---|---|
| `POST /catalog/products` | Create |
| `PATCH /catalog/products/{id}` | Update (partial) |
| `POST /catalog/products/{id}/photo` | Upload single photo |
| `DELETE /catalog/products/{id}/photo` | Remove photo |

On create from missing-item-request prefill, server also:
- `POST /catalog/missing-item-requests/{req_id}/resolve` with `{ resolution: 'PRODUCT_CREATED', product_id }`

## Optimistic UI

**NO.** Catalog mutations are too consequential (cascading effects on sales, reports, search). Wait for server.

## Locking

Optimistic version check via `Product.version`. Concurrent edit: 409 → modal "Başka kullanıcı düzenliyor".

## Draft autosave

**NO.** Product mutation is intentional; explicit Save. Avoids half-finished products contaminating catalog.

## Keyboard flow

| Key | Action |
|---|---|
| On enter (create) | Focus → code field |
| On enter (edit) | Focus → display_name field |
| Tab | code → name → description → brand → category → season → vat_rate → photo upload → variants link → Save |
| `Ctrl+S` | Save (stays on page; "Kaydedildi" toast) |
| `Ctrl+Enter` | Save and go to Variants (3.B.3) |
| `Esc` | Back to product list (confirm if dirty) |

## Barcode flow

**Scanner DISABLED.** Product master has no barcode; barcodes belong to variants (3.B.3).

## Speed budget

| Action | p95 target |
|---|---|
| Initial render (edit) | < 300ms |
| Save | < 500ms |
| Photo upload | < 2s (1MB max after client resize) |

## Permissions

| Permission | Required for |
|---|---|
| `catalog.products.create` | Create new |
| `catalog.products.edit` | Edit existing |
| `catalog.products.upload_photo` | Photo upload (subset of edit) |
| `catalog.products.change_code_after_sale` | Code edit when product has completed sales |
| `catalog.taxonomy.manage` | Add new brand / category / season inline |

## Field-by-field specification

### Ürün Kodu (code)

- Type: text, required, unique per tenant
- Pattern: alphanumeric + hyphens, max 32 chars
- Auto-suggest button: server generates next code based on category (e.g. "T-101" if last was T-100)
- Validation: server checks uniqueness on blur (debounced 400ms)
- Inline error: "Bu kod kullanımda"
- **Edit mode after completed sale**: requires `catalog.products.change_code_after_sale` permission. UI shows: "Bu üründen X satış yapılmış. Kod değişikliği POS taramasını etkileyebilir."

### Ad (display_name)

- Type: text, required, max 200 chars
- Shown in: POS, receipts, reports
- No uniqueness constraint

### Açıklama (description)

- Type: textarea, optional, max 1000 chars
- Plain text (no markdown MVP)
- Shown in product detail; NOT in POS

### Marka (brand)

- Type: Select with search (Mantine Combobox)
- Source: `GET /catalog/brands`
- "+ Yeni Marka Ekle" inline mini-modal
- **Required: NO** (boutique reality)
- Empty display: "Markasız" or "—"

#### Brand normalization (server-side, before INSERT)

- Trim whitespace
- Collapse multiple spaces
- Strip trademark chars (®, ™, ©)
- Case-insensitive duplicate detection
- "Benzer marka bulundu: POLO" warning before create (no auto-merge MVP)

### Kategori (category)

- Type: TreeSelect (hierarchical)
- Required: YES
- "+ Yeni Kategori Ekle" requires `catalog.taxonomy.manage`
- Affects: reporting, default attribute templates (v1.1+)

### Sezon (season)

- Type: Select
- Required: NO

### KDV Oranı (vat_rate)

- Type: Select from allowed values (1%, 8%, 18%, 20%)
- Required: YES
- Default: 20% (most common Türkiye textile)
- Change after sale: warning but allowed; "Geçmiş satışlar etkilenmez (snapshot)"

### Foto (single image upload)

- Type: File input + drag-drop area
- Required: NO
- Accepted: jpg, png, webp
- Max raw size: 5MB
- **Pipeline**:
  - Client pre-shrink: long edge max 1200px, JPEG quality 0.85 (via browser-image-compression library)
  - Server authoritative transform: full + thumbnail (200×200), metadata strip, canonical format
- Stored via DocumentStorage abstraction (Phase 6.F)
- No crop, no gallery, no reorder MVP

### Aktif (is_active)

- Type: Switch
- Default: true (new); preserved on edit
- Off = soft delete; disappears from POS search
- Stock + variants preserved
- Off requires confirm with current variant/stock count

### track_inventory (HIDDEN MVP)

- Default: true
- NOT shown in UI MVP
- Surfaced v1.1+ when non-inventory items (gift cards, services) added

## Form layout

```
┌─ Catalog Shell ───────────────────────────────────────────────────┐
│  [Ürünler]  [Eksik Bildirimler]  [Özellikler]                     │
├───────────────────────────────────────────────────────────────────┤
│                                                                    │
│  Top bar:                                                          │
│  [← Geri]  Yeni Ürün / Düzenle: T-shirt Basic                     │
│  [Pasif badge if !is_active]    [Aktif Switch]                    │
│                                                                    │
│  ┌─ Form (2-column on wide screens) ───────────────────────────┐ │
│  │                                                                │ │
│  │  LEFT (60%)                       RIGHT (40%)                 │ │
│  │                                                                │ │
│  │  Ürün Kodu *  [____] [⟳ Öner]    ┌─ Foto ──────────────┐   │ │
│  │  Ad *         [_________________] │                       │   │ │
│  │  Açıklama     [_________________  │  [Drag-drop or click] │   │ │
│  │               _________________]  │                       │   │ │
│  │                                    │  Or                   │   │ │
│  │  Marka        [Polo ▾] [+ Yeni]   │                       │   │ │
│  │  Kategori *   [Üst Giyim > ▾]    │  [📷 Preview if set] │   │ │
│  │  Sezon        [SS24 ▾]            │  [🗑 Sil]             │   │ │
│  │  KDV Oranı *  [%20 ▾]             │                       │   │ │
│  │                                    └───────────────────────┘   │ │
│  └──────────────────────────────────────────────────────────────┘ │
│                                                                    │
│  ┌─ Sonraki adımlar (edit mode only) ──────────────────────────┐ │
│  │ [Varyantlar (3.B.3)]  [Fiyatlandırma (3.B.4)]               │ │
│  │ → Variants count: 8 · Stok: 24                                │ │
│  └──────────────────────────────────────────────────────────────┘ │
│                                                                    │
│  [Esc İptal]                                  [Ctrl+S Kaydet]     │
│                                              [Kaydet ve Varyantlar →] │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

Note: "Kaydet ve Varyantlar →" is the **primary CTA** (boutique reality: product without variants is rare).

## Edge cases

| # | Scenario | Behavior |
|---|---|---|
| 1 | Save with code conflict | Server 409 + conflicting_product_id; inline error with clickable link |
| 2 | VAT change on product with sales | Warning "X satış var; yeni KDV gelecek satışlara uygulanır (snapshot korunur)" |
| 3 | Photo upload mid-fill, network fail | Toast "Yükleme başarısız"; form state preserved; retry without losing other fields |
| 4 | Discard unsaved changes (Esc) | Confirm if dirty |
| 5 | Browser back button mid-edit | React Router guard: same confirm as Esc |
| 6 | Concurrent edit (409 on save) | Modal "Başka kullanıcı düzenledi. Yenile?"; 3-way diff v1.1+; MVP just refresh |
| 7 | Deactivate confirm | "T-shirt Basic ürününü pasife al? 8 varyant, 24 adet stok mevcut. Stok satılabilir kalır." |
| 8 | Create from missing-item-request prefill | Banner "Bu ürün şu eksik bildirimden oluşturuluyor: {req_id}"; barcode/description prefilled; on save → missing_item_requests.status = RESOLVED |
| 9 | Server validation rejection | Inline field errors from response |
| 10 | Brand/category quick-add | Inline modal; permission `catalog.taxonomy.manage`; created and selected in parent form |
| 11 | Code change after sale, no permission | UI shows lock icon; tooltip "Yetkiniz yok"; manager request flow (no automation MVP) |

## Implementation notes

- React Hook Form + Zod schema validation (Phase 6.E)
- Mantine: TextInput, Textarea, Select, TreeSelect, NumberInput, FileInput, Switch
- Photo upload: `browser-image-compression` for client pre-shrink
- Server stores via DocumentStorage abstraction; URL stored in `products.photo_url`
- Validation Zod schema mirrors server Bean Validation; types auto-generated from OpenAPI
- Form dirty tracked via React Hook Form's `isDirty`
- Code auto-suggest: `GET /catalog/products/suggest-code?category_id=...`
- "Save and go to Variants" disabled until first save (needs product_id)
