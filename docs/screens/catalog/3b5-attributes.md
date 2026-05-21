# 3.B.5 — Attribute Configuration

> **Status:** Locked (Phase 3.B)
> **Route:** `/catalog/attributes`
> **Catalog Shell tab:** "Özellikler"

## Purpose

Manage tenant's catalog attribute palette: colors, sizes, materials. Drives variant matrix builder (3.B.3) and POS variant display.

NOT a daily-use screen. Manager visits when: new season requires new sizes, new color introduced, typo correction, deactivate discontinued.

## Aggregate ownership (explicit)

- **Writes** Attribute aggregate (per tenant)
- **Reads** attribute_types (tenant-owned, system-seeded for COLOR/SIZE/MATERIAL/FIT; tenant can add custom)
- **DOES NOT** touch product_variants directly — but mutations trigger outbox events that refresh denormalized `variant.display_name` fields

## Hybrid attribute type model

### System-seed types (auto-created on tenant signup)

| system_key | Default display_name |
|---|---|
| COLOR | Renk |
| SIZE | Beden |
| MATERIAL | Materyal |
| FIT | Kalıp |

Properties:
- `is_system_seed = true`
- `system_key` IMMUTABLE (platform-semantic identifier)
- `display_name` editable (tenant can translate)
- `is_active` can be set false (jewelry tenant may hide SIZE)
- **Delete forbidden**; deactivate only

### Custom types (tenant-created)

- `is_system_seed = false`
- `system_key` NULL (no platform semantic)
- Fully manageable

### Why hybrid

- Platform standardization preserved (cross-tenant analytics consistent on COLOR/SIZE)
- Tenant flexibility (jewelry adds STONE_TYPE, METAL_KARAT)
- Schema stays simple (single table with tenant_id)

## Mutability table

| Field | Mutable? |
|---|---|
| `system_key` | NO (immutable identity for system-seed) |
| `display_name` | Yes (with usage warning if in use) |
| `attribute_type_id` (on attributes) | NO (COLOR ↔ SIZE forbidden) |
| `color_hex` | Yes |
| `sort_order` | Yes (drag-drop) |
| `is_active` | Yes |

## Reads

- `GET /catalog/attribute-types` — Tenant's types
- `GET /catalog/attributes?type_id={typeId}` — Values for type
- `GET /catalog/attributes/{id}/usage` — `{ variant_count, sample_variant_skus[5] }`

## Writes

| Endpoint | Purpose |
|---|---|
| `POST /catalog/attribute-types` | Create custom type |
| `PATCH /catalog/attribute-types/{id}` | Rename / sort / is_active |
| `DELETE /catalog/attribute-types/{id}` | Soft delete; rejected if attributes exist OR is_system_seed=true |
| `POST /catalog/attributes` | Create attribute |
| `PATCH /catalog/attributes/{id}` | Rename / color_hex / sort / is_active |
| `POST /catalog/attributes/{id}/deactivate` | |
| `POST /catalog/attributes/{id}/reactivate` | |

Hard delete NOT exposed.

## Optimistic UI

- Per-row inline edit: yes
- Rename with warning: NO (modal confirm required)
- Reorder (drag sort_order): yes
- Deactivate: yes

## Locking

Optimistic version on attribute rows.

## Draft autosave

- Per-row inline edit: blur-commit (debounced 400ms)
- Rename: explicit modal save

## Keyboard flow

| Key | Action |
|---|---|
| Tab | type selector → attribute list → "+ Yeni" |
| `/` | Focus search |
| `Enter` | Edit focused row inline |
| `Esc` | Cancel edit |
| `Ctrl+N` | New attribute |
| `Ctrl+D` | Deactivate (confirm) |
| `↓ / ↑` | Row navigation |

## Barcode flow

Scanner DISABLED. Attributes are taxonomy, not scannable items.

## Speed budget

| Action | p95 target |
|---|---|
| Initial render | < 200ms |
| Inline edit commit | < 400ms |
| Reorder (drag) | < 200ms |
| Rename with usage check + preview | < 600ms |

## Permissions

| Permission | Default |
|---|---|
| `catalog.taxonomy.manage` | STORE_MANAGER+ |
| `catalog.taxonomy.manage_types` | STORE_MANAGER+ (create/edit custom types) |
| `catalog.taxonomy.deactivate` | STORE_MANAGER+ |

## short_code normalization

Application-layer normalization before INSERT/UPDATE:
1. Trim whitespace
2. Convert to uppercase

Schema CHECK constraint:
```sql
CHECK (short_code ~ '^[A-Z0-9]{1,8}$')
```

UNIQUE per `(attribute_type_id, short_code)`. Examples:
- "BLK" (Black/Siyah)
- "M" (Medium)
- "WHT" (White)

## color_hex field

Optional, COLOR type only:
- Hidden in UI for non-COLOR types
- Server rejects if set on non-COLOR attribute
- Format: `#RRGGBB` (validated client + server)

Visual benefit: chips in catalog UI, filter pills, swatches.

## Display name composition (refresh strategy)

When `attribute.display_name` changes:
1. Outbox event `AttributeDisplayNameChangedV1` emitted
2. Application module listener finds all variants using attribute
3. `VariantDisplayNameComposer` (Java) recomputes display_name per variant
4. Bulk update `product_variants.display_name`
5. Eventually consistent ~1-2s

See ADR-019.

## usage_count refresh

Event-driven only (no nightly job MVP):
- `VariantCreatedV1` → `attributes.usage_count++` for used attributes
- `VariantDeactivatedV1` → `usage_count--`
- `AttributeAttachedToVariantV1` → `usage_count++`

Discrepancy rare; admin tool for manual reconciliation v1.1+.

## Edge cases

| # | Scenario | Behavior |
|---|---|---|
| 1 | Rename attribute in use | Modal preview shown; confirm required; outbox event → variant display_name refresh |
| 2 | Deactivate attribute in use | Confirm "Bu rengi 12 varyant kullanıyor. Pasife alınca yeni varyantlarda seçilemez. Mevcut varyantlar etkilenmez." |
| 3 | Duplicate display_name within type | 409 "Aynı isim bu türde var" |
| 4 | Custom type creation | Inline modal: name + sort_order; no cross-tenant validation |
| 5 | Reorder via drag | sort_order updated; affects 3.B.3 builder display order |
| 6 | short_code collision | Server validates uniqueness within type; suggests alternative |
| 7 | color_hex on non-COLOR type | Field hidden UI; server rejects |
| 8 | Deactivate type with active attributes | Allowed; UI hidden but FK references preserved; attributes still queryable historically |
| 9 | Delete system-seed type | Forbidden; UI shows "Sistem türü, silinemez" |
| 10 | Rename system-seed type display_name | Allowed (i18n use case: "Renk" → "Color") |

## Layout

```
┌─ Catalog Shell > Attributes ──────────────────────────────────────┐
│  [Ürünler]  [Eksik Bildirimler]  [Özellikler]                     │
├───────────────────────────────────────────────────────────────────┤
│                                                                    │
│  Sol nav (vertical type list):                                     │
│  ┌──────────────────┐                                              │
│  │ ✓ Renk (12)      │  ← system-seed                              │
│  │   Beden (8)      │  ← system-seed                              │
│  │   Materyal (3)   │  ← system-seed                              │
│  │   Kalıp (2)      │  ← system-seed                              │
│  │   ─────────────  │                                              │
│  │   Taş Türü (5)   │  ← custom                                   │
│  │   [+ Yeni Tür]   │                                              │
│  └──────────────────┘                                              │
│                                                                    │
│  Sağ panel (selected: Renk):                                       │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ Renk değerleri                          [+ Yeni Renk]       │  │
│  │ ─────────────                                                │  │
│  │ ⌕ [search]                                                   │  │
│  │                                                              │  │
│  │ ⋮⋮ █ Siyah         BLK   #000000   12 varyant   [⋯]        │  │
│  │ ⋮⋮ ▢ Beyaz         WHT   #FFFFFF   8 varyant    [⋯]        │  │
│  │ ⋮⋮ ▢ Kırmızı       RED   #DC2626   5 varyant    [⋯]        │  │
│  │ ⋮⋮ ▢ Mavi          BLU   #2563EB   3 varyant    [⋯]        │  │
│  │ ⋮⋮ ▢ Ekru          ECR   #F5F1E8   0 varyant    [⋯]        │  │
│  │ ⋮⋮ ▢ Lacivert 🚫   NAV   #1E3A8A   2 varyant    [⋯]        │  │
│  │                                                              │  │
│  │ ⋮⋮ = drag handle                                             │  │
│  │ 🚫 = deactivated                                              │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Layout — Rename modal (with preview)

```
┌─ İsim Değiştir ──────────────────────────────────────────────────┐
│                                                                    │
│  Mevcut: Siyah                                                     │
│  Yeni:   [Lacivert]                                                │
│                                                                    │
│  ⚠ Bu değer 12 varyantta kullanılıyor:                            │
│     T-100-BLK-S, T-100-BLK-M, T-100-BLK-L, +9 daha                │
│                                                                    │
│  Değişiklik tüm bu varyantları etkileyecek:                       │
│                                                                    │
│  Önce:                                                             │
│    T-shirt Basic / Siyah / M                                       │
│  Sonra:                                                            │
│    T-shirt Basic / Lacivert / M                                    │
│                                                                    │
│  [İptal]                              [Onayla ve Uygula]           │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Layout — New attribute modal

```
┌─ Yeni Renk ──────────────────────────────────────────────────────┐
│                                                                    │
│  Görünen Ad:   [Antrasit          ]                                │
│  Kısa Kod:     [ANT]                                                │
│  Renk Kodu:    [#374151]  [color picker]                            │
│                                                                    │
│  Önizleme:                                                         │
│  ┌────────────────────────────────┐                                │
│  │ █ Antrasit  (ANT)               │                                │
│  └────────────────────────────────┘                                │
│                                                                    │
│  [İptal]                              [Oluştur]                    │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Audit events

- `attribute_type_created` (custom)
- `attribute_type_renamed`
- `attribute_type_deactivated`
- `attribute_created`
- `attribute_renamed` (triggers variant display refresh)
- `attribute_color_hex_changed`
- `attribute_sort_order_changed`
- `attribute_deactivated`
- `attribute_reactivated`

## Implementation notes

- Drag-drop reorder via Mantine Sortable
- color_hex uses Mantine ColorInput component
- color_hex column only rendered for COLOR-type attributes
- Usage count via projection (event-driven); refreshed on attribute mutations
- Rename modal fetches `GET /attributes/{id}/usage` at open
- Preview text computed via `VariantDisplayNameComposer` (Java) at request time
- is_system_seed types: rename allowed (i18n), delete forbidden, deactivate allowed
