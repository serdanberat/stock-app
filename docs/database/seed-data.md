# Seed Data

> **Status:** Locked (Phase 2E)
> **Migration file (Stage A):** `002_system_seed_lookups.sql`
> **Application logic (Stage B):** `015_tenant_onboarding_template.sql` plus runtime tenant CREATE handler

The schema is seeded in two stages.

---

## Stage A — System Seed (Once, at DB init)

All rows in Stage A have `tenant_id IS NULL`. They are system-wide lookups shared across all tenants.

### Currencies (8 rows)

| Code | Display | Symbol | Decimals | Type | Active in MVP |
|---|---|---|---|---|---|
| TRY | Türk Lirası | ₺ | 2 | FIAT | ✅ |
| USD | US Dollar | $ | 2 | FIAT | ✅ |
| EUR | Euro | € | 2 | FIAT | ✅ |
| GBP | British Pound | £ | 2 | FIAT | ✅ |
| XAU | Gold (gram) | gr | 4 | METAL | ❌ (v2 jewelry) |
| XAG | Silver (gram) | gr | 4 | METAL | ❌ (v2 jewelry) |
| XAU22 | Gold 22K (gram) | gr | 4 | METAL | ❌ (v2 jewelry) |
| XAU14 | Gold 14K (gram) | gr | 4 | METAL | ❌ (v2 jewelry) |

**Invariant**: TRY can never be deactivated (application enforced).

### FX Rate Sources (7 rows)

| Code | Display | Type | Active in MVP | Impl. Class |
|---|---|---|---|---|
| TCMB | Türkiye Cumhuriyet Merkez Bankası | DAILY | ✅ | TcmbProvider |
| HAREM | Harem Altın & Döviz | REALTIME (60s) | ✅ | HaremProvider |
| MANUAL | Manual Entry | MANUAL | ✅ | ManualProvider |
| FOREKS | Foreks | REALTIME (30s) | ❌ | ForeksProvider |
| GOLDISTANBUL | Goldistanbul | REALTIME (30s) | ❌ | GoldIstanbulProvider |
| BIGPARA | Bigpara | REALTIME (60s) | ❌ | BigparaProvider |
| DOVIZCOM | Doviz.com | REALTIME (60s) | ❌ | DovizComProvider |

**Invariant**: MANUAL always active (fallback when no internet).

### System Roles (6 rows)

| Code | Display | Permissions (summary) |
|---|---|---|
| SUPER_ADMIN | Süper Admin | `*` (all) |
| STORE_MANAGER | Mağaza Müdürü | sales.*, returns.*, inventory.*, parties.*, reports.*, register.*, override permissions |
| CASHIER | Kasiyer | sales.create, sales.complete, sales.modify_cart, sales.return.create, register.open, register.close.initiate (no cost visibility) |
| STOCK_CLERK | Stok Personeli | inventory.transfer.*, inventory.count.*, inventory.adjust.create, purchases.create, purchases.post |
| ACCOUNTANT | Muhasebeci | financial.read, reports.read, payments.create, payments.complete |
| AUDITOR | Denetçi | `*.read`, audit.* |

All 6 are `is_system = true`; trigger prevents modification or deletion.

### Reason Codes (12 rows, system-wide)

**Domain: STOCK_ADJUSTMENT**

| Code | Display | Requires Notes |
|---|---|---|
| HASAR | Hasar | No |
| HIRSIZLIK | Hırsızlık | **Yes** |
| HEDIYE | Hediye/Promosyon | No |
| NUMUNE | Numune | No |
| DEMODE | Demode/Sezon Sonu | No |
| SISTEM_HATA | Sistem Hatası Düzeltme | **Yes** |
| DIGER | Diğer | **Yes** |

**Domain: TRANSFER_LOSS** (Phase 2D requirement)

| Code | Display | Manager Approval | Notes |
|---|---|---|---|
| LOST_IN_TRANSIT | Kargoda Kayıp | No | Yes |
| DAMAGED_IN_TRANSIT | Kargoda Hasar | No | Yes |
| RECEIVED_SHORT | Eksik Geldi | No | Yes |
| PROVIDER_ERROR | Kargo Şirketi Hatası | No | No |
| INTERNAL_PILFERAGE | İç Hırsızlık Şüphesi | **Yes** | **Yes** |

Tenants may add their own reason codes with `tenant_id = <their_uuid>` for custom workflows.

---

## Stage B — Tenant Onboarding Seed

When a tenant CREATE flow runs (signup, admin provisioning), the application performs the following inside one transaction:

### 1. Tenant row

```sql
INSERT INTO tenants (
  code, display_name, industry, status,
  trial_started_at, trial_ends_at,
  preferred_fx_source, default_currency, default_vat_rate,
  feature_flags, settings
) VALUES (
  $1, $2, $3, 'TRIAL',
  now(), now() + interval '30 days',
  'TCMB', 'TRY', 20.00,
  '{
    "allow_admin_register_reopen": false,
    "allow_admin_sale_reverse": false,
    "allow_admin_return_reverse": false,
    "allow_blind_return": false,
    "allow_negative_stock": false,
    "auto_block_on_overdue_days": null,
    "blind_return_max_amount_per_day": 5000,
    "blind_return_max_count_per_day": 10,
    "blind_return_manager_threshold": 1000,
    "blind_return_customer_frequency_limit": 3,
    "blind_return_excluded_categories": []
  }'::jsonb,
  '{
    "return_grace_days": 14,
    "return_manager_threshold": 1000,
    "product_code_template": "{CATEGORY}-{YEAR}-{SEQ:5}",
    "price_cipher_keyword": null,
    "tenant_prefix_for_barcodes": "20",
    "z_report_number_prefix": null
  }'::jsonb
) RETURNING id;
```

### 2. Initial owner user + SUPER_ADMIN role

```sql
INSERT INTO users (tenant_id, email, display_name, status, password_hash, email_verified_at)
  VALUES (...) RETURNING id;

INSERT INTO user_role_assignments (tenant_id, user_id, role_id, store_scope_ids)
  SELECT $tenant_id, $user_id, id, NULL FROM roles WHERE code = 'SUPER_ADMIN' AND is_system = true;
```

### 3. VIRTUAL_IN_TRANSIT store (Phase 2A invariant — mandatory)

```sql
INSERT INTO stores (tenant_id, code, display_name, store_type, status)
VALUES ($tenant_id, 'VIRTUAL_TRANSIT', 'Transfer Aracında', 'VIRTUAL_IN_TRANSIT', 'ACTIVE');
```

### 4. Tenant-specific attribute types (clones from defaults)

The five standard attribute types (Color, Size, Material, Model, Gender) are created per tenant. They are NOT system-wide because tenants may rename them (e.g. "Beden" instead of "Size") or change display order.

```sql
INSERT INTO attribute_types (tenant_id, code, display_name, is_system, display_type, display_order, status)
VALUES
  ($tenant_id, 'COLOR', 'Renk', true, 'COLOR_SWATCH', 1, 'ACTIVE'),
  ($tenant_id, 'SIZE', 'Beden', true, 'DROPDOWN', 2, 'ACTIVE'),
  ($tenant_id, 'MATERIAL', 'Materyal', true, 'TEXT', 3, 'ACTIVE'),
  ($tenant_id, 'MODEL', 'Model', true, 'TEXT', 4, 'ACTIVE'),
  ($tenant_id, 'GENDER', 'Cinsiyet', true, 'DROPDOWN', 5, 'ACTIVE');
```

### 5. Default price list

```sql
INSERT INTO price_lists (tenant_id, code, display_name, is_default, currency, status, valid_from)
VALUES ($tenant_id, 'DEFAULT', 'Standart Fiyat Listesi', true, 'TRY', 'ACTIVE', now());
```

### 6. Initial document sequence rows

Created lazily on first use; not strictly required at onboarding. Application's `allocate_sequence` function handles `ON CONFLICT DO NOTHING`.

### 7. Initial account_movement_sequences

Same — created lazily per `account_profile` on first ledger entry.

### Onboarding does NOT create

- `cash_registers` — tenant configures these from UI per store
- `categories` — tenant defines based on their product line
- `brands`, `seasons` — domain-specific, tenant-defined
- `attribute_values` — tenant defines per attribute_type

---

## Idempotency

Stage A migration uses `ON CONFLICT DO NOTHING` everywhere:

```sql
INSERT INTO currencies (...) VALUES (...) ON CONFLICT (code) DO NOTHING;
INSERT INTO roles (...) VALUES (...) ON CONFLICT (tenant_id, code) DO NOTHING;
INSERT INTO reason_codes (...) VALUES (...) ON CONFLICT (tenant_id, domain, code) DO NOTHING;
```

Stage B is wrapped in a transaction; a failure rolls back the entire tenant creation atomically.
