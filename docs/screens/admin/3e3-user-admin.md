# 3.E.3 — User & Role Admin

> **Status:** Locked (Phase 3.E)
> **Routes:**
> - `/admin/users` — List
> - `/admin/users/new` — Create
> - `/admin/users/{id}` — Edit

## Purpose

Manage tenant's users: create, assign roles + stores, reset credentials, deactivate. Admin-only area.

## Aggregate ownership (explicit)

- **Writes** User aggregate + UserRoleAssignment + UserStoreAssignment

## Reads

- `POST /admin/users/search`
- `GET /admin/users/{id}`
- `GET /admin/roles`
- `GET /admin/users/{id}/effective-permissions` — Returns merged permissions from all assigned roles, with origin role name per permission

## Writes

- `POST /admin/users`
  - Body: `{ display_name, email, initial_password, roles[], store_ids[] }`
- `PATCH /admin/users/{id}`
  - Body: `{ display_name?, email?, roles?, store_ids?, is_active? }`
- `POST /admin/users/{id}/reset-password`
  - Generates random temp password; emailed (Phase 6.F worker)
  - Forces password change on next login
- `POST /admin/users/{id}/reset-manager-pin`
  - Clears `manager_pin_hash`; user re-sets via profile flow

## Session authorization policy

When role/permission changes for a user with active session:
- **MVP**: change takes effect at next token refresh (~15min) or session expiry
- **Force-logout endpoint v1.1+** if needed

UI shows hint when editing user with active session:
```
"Bu kullanıcının aktif oturumu var. Yetkiler ~15dk içinde güncel olacak."
```

## Effective permission preview (CRITICAL)

When multiple roles assigned (e.g. CASHIER + STOCK_CLERK):

Read-only collapsible section in edit form shows:
- Combined permission set
- Per-permission origin (which role grants it)
- Conflicts highlighted (none in MVP; placeholder for future deny rules)

Example display:

```
┌─ Effective Permissions (CASHIER + STOCK_CLERK) ──────────────────┐
│ sales.create                from CASHIER                          │
│ sales.complete              from CASHIER                          │
│ inventory.stock.view        from STOCK_CLERK                     │
│ inventory.transfers.create  from STOCK_CLERK                     │
│ inventory.counts.count      from STOCK_CLERK                     │
│ ...                                                                │
│ [Expand all 24 permissions]                                       │
└────────────────────────────────────────────────────────────────────┘
```

## Optimistic UI

NO. Permission changes are sensitive.

## Permissions

| Permission | Default |
|---|---|
| `admin.users.view` | STORE_MANAGER+ (view); SUPER_ADMIN (mutate) |
| `admin.users.create` | SUPER_ADMIN |
| `admin.users.edit` | SUPER_ADMIN (all fields); STORE_MANAGER (own store users, restricted fields per matrix below) |
| `admin.users.reset_password` | SUPER_ADMIN |
| `admin.users.reset_manager_pin` | SUPER_ADMIN, STORE_MANAGER |
| `admin.users.assign_role` | SUPER_ADMIN |

### STORE_MANAGER edit scope (explicit allowlist)

To prevent privilege escalation, STORE_MANAGER's edit capability is bound by an explicit field-level allowlist. Server enforces at PATCH endpoint, not just route-level.

| Operation | STORE_MANAGER | SUPER_ADMIN |
|---|---|---|
| Activate/deactivate cashier (own store) | ✓ | ✓ |
| Reset cashier password | ✗ | ✓ |
| Reset manager PIN (own store users) | ✓ | ✓ |
| Edit user display_name (own store users) | ✓ | ✓ |
| Change user email | ✗ | ✓ |
| Assign roles | ✗ | ✓ |
| Assign stores | ✗ | ✓ |
| Create user | ✗ | ✓ |
| Delete user | ✗ (deactivate only) | ✗ (deactivate only) |

**Rationale**: STORE_MANAGER scope is operational user lifecycle for own store (activate/deactivate/PIN reset). Identity mutation (email) and authorization mutation (role/store assignment) are SUPER_ADMIN territory. This eliminates the "STORE_MANAGER promotes self to SUPER_ADMIN" attack surface.

**Server enforcement**: field-level permission check in PATCH endpoint. If STORE_MANAGER includes `roles` or `store_ids` in PATCH body → 403 (not 200 with silent drop).

### Multi-role semantics (no deny rules MVP)

```
effective_permissions = UNION(all permissions from all assigned roles)
```

**No deny rules. No override semantics. Multi-role is purely additive in MVP.**

This is a documented constraint, not an oversight. If a user is CASHIER + AUDITOR, both grant; nothing denies. No surprise.

**v1.1+ consideration**: if business needs role denial rules (e.g. "AUDITOR explicitly blocks write permissions even if combined with STORE_MANAGER"), introduce a separate `role_deny_rules` table with explicit precedence — not implicit role ordering.

## Manager PIN reset

Clears `users.manager_pin_hash`; sets `manager_pin_set_at = null`.

User must re-set PIN via own profile (not admin form).

**Audit event**: `manager_pin_force_reset` (with actor + target user)

Fraud-sensitive: PIN reset by admin must be auditable.

## Edge cases

| # | Scenario | Behavior |
|---|---|---|
| 1 | Reset password for user with active session | Old session continues to expiry (15min); new password effective for next login |
| 2 | Deactivate self | Server rejects: 403 "Kendi hesabını pasife alamazsın" |
| 3 | Last SUPER_ADMIN deactivation | Server rejects: 422 "Son super admin pasife alınamaz" |
| 4 | Email collision on create | 409 with existing user reference |
| 5 | Initial password generation | 12 chars, mixed case + digit + symbol; emailed via document worker; forced rotation on first login (flag in users table) |

## Layout — List

```
┌─ Admin Shell > Kullanıcılar ──────────────────────────────────────┐
│                                                                    │
│  ⌕ [Ad veya e-posta...]      [+ Yeni Kullanıcı]                   │
│  Rol: [Tümü ▾]   Durum: [Aktif ▾]                                 │
│                                                                    │
│  ┌─ Users ───────────────────────────────────────────────────┐   │
│  │ Ad           │E-posta       │Roller         │Mağazalar│Dur│   │
│  ├──────────────┼──────────────┼───────────────┼─────────┼───┤│  │
│  │ Ayşe Yılmaz  │ayse@...      │CASHIER        │Beyoğlu  │A  │   │
│  │ Mehmet K.    │mehmet@...    │STORE_MANAGER  │Beyoğlu  │A  │   │
│  │ Selin Ç.     │selin@...     │CASHIER, STOCK │Kadıköy  │A  │   │
│  │ Eski Hesap   │old@...       │CASHIER        │—        │P  │   │
│  └────────────────────────────────────────────────────────────┘   │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Layout — Edit form

```
┌─ Kullanıcı Düzenle: Selin Çelik ──────────────────────────────────┐
│                                                                    │
│  Ad: [Selin Çelik]                                                 │
│  E-posta: [selin@example.com]                                      │
│  Aktif: [☑]                                                        │
│                                                                    │
│  Roller (birden fazla seçilebilir):                                │
│  ☑ CASHIER                                                         │
│  ☑ STOCK_CLERK                                                     │
│  ☐ STORE_MANAGER                                                   │
│  ☐ ACCOUNTANT                                                      │
│  ☐ AUDITOR                                                         │
│  ☐ SUPER_ADMIN                                                     │
│                                                                    │
│  Mağazalar:                                                        │
│  ☑ Beyoğlu                                                         │
│  ☑ Kadıköy                                                         │
│  ☐ Beşiktaş                                                        │
│                                                                    │
│  ▶ Etkin Yetkiler (24)  [genişlet]                                 │
│                                                                    │
│  Tehlikeli işlemler:                                               │
│  [Şifre Sıfırla]    [Manager PIN Sıfırla]    [Pasife Al]          │
│                                                                    │
│  ⚠ Bu kullanıcının aktif oturumu var. Değişiklikler ~15dk içinde │
│     etkin olacak.                                                  │
│                                                                    │
│  [Esc İptal]                              [Kaydet]                 │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Audit events

- `user_created`
- `user_updated`
- `user_deactivated` / `user_reactivated`
- `user_role_assigned` / `user_role_removed`
- `user_store_assigned` / `user_store_removed`
- `user_password_reset` (admin-initiated)
- `manager_pin_force_reset` (with target + actor)
