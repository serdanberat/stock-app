# API Endpoint Catalogue

> **Status:** Locked (Phase 5)
> **Source:** Phase 3 screen specs + Phase 4 module contracts + Phase 5 API conventions
> **Last updated:** 2026-05-21

This is the single index of all ~140 endpoints across 10 modules. Conventions defined in `05-api-conventions.md`.

## Notation

- **Idem** = X-Idempotency-Key required (per `05-api-conventions.md` § Idempotency)
- **Perm** = Required permission code
- **Screen** = Phase 3 screen reference
- **Req/Resp** = Request / Response DTO name

DTO names use convention: `<Action><Resource>Request` / `<Resource>Response`. Examples: `CreateSaleRequest`, `SaleResponse`, `CommitPurchaseInvoiceRequest`.

---

## 1. Identity & Auth

### Authentication

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| POST | /auth/login | (public) | NO | LoginRequest | LoginResponse | login |
| POST | /auth/refresh | (public) | NO | RefreshTokenRequest | LoginResponse | — |
| POST | /auth/logout | (any) | NO | — | — | — |
| POST | /auth/manager-pin-verify | (any) | NO | VerifyManagerPinRequest | ManagerOverrideTokenResponse | 3.A.4 |

### Current user

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| GET | /me | (any) | — | — | CurrentUserResponse | (all) |
| GET | /me/permissions | (any) | — | — | EffectivePermissionsResponse | — |
| POST | /me/set-manager-pin | (any) | NO | SetManagerPinRequest | — | profile |

### User admin

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| POST | /admin/users/search | admin.users.view | NO | SearchUsersRequest | PageResponse&lt;UserSummary&gt; | 3.E.3 |
| POST | /admin/users | admin.users.create | YES | CreateUserRequest | UserResponse | 3.E.3 |
| GET | /admin/users/{id} | admin.users.view | — | — | UserResponse | 3.E.3 |
| PATCH | /admin/users/{id} | admin.users.edit | NO | UpdateUserRequest | UserResponse | 3.E.3 |
| GET | /admin/users/{id}/effective-permissions | admin.users.view | — | — | EffectivePermissionsResponse | 3.E.3 |
| POST | /admin/users/{id}/deactivate | admin.users.edit | YES | DeactivateUserRequest | — | 3.E.3 |
| POST | /admin/users/{id}/reactivate | admin.users.edit | YES | — | — | 3.E.3 |
| POST | /admin/users/{id}/reset-password | admin.users.reset_password | YES | — | ResetPasswordResponse | 3.E.3 |
| POST | /admin/users/{id}/reset-manager-pin | admin.users.reset_manager_pin | YES | — | — | 3.E.3 |

### Roles

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| GET | /admin/roles | admin.users.view | — | — | List&lt;RoleResponse&gt; | 3.E.3 |
| GET | /admin/roles/{id}/permissions | admin.users.view | — | — | List&lt;PermissionResponse&gt; | 3.E.3 |

### Stores

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| GET | /stores | (any) | — | — | List&lt;StoreResponse&gt; | (many) |
| GET | /stores/{id} | (any) | — | — | StoreResponse | — |
| POST | /admin/stores | admin.stores.create | YES | CreateStoreRequest | StoreResponse | — |
| PATCH | /admin/stores/{id} | admin.stores.edit | NO | UpdateStoreRequest | StoreResponse | — |
| POST | /admin/stores/{id}/close | admin.stores.edit | YES | CloseStoreRequest | StoreResponse | — |

### Tenant settings

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| GET | /admin/settings | admin.settings.view | — | — | TenantSettingsResponse | 3.E.4 |
| PATCH | /admin/settings | admin.settings.edit_operational | NO | UpdateOperationalSettingsRequest | TenantSettingsResponse | 3.E.4 |
| PATCH | /admin/settings/dangerous | admin.settings.edit_dangerous | YES | UpdateDangerousFlagRequest | TenantSettingsResponse | 3.E.4 |

---

## 2. Catalog

### Products

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| POST | /catalog/products/search | catalog.products.view | NO | SearchProductsRequest | PageResponse&lt;ProductSummary&gt; | 3.B.1 |
| POST | /catalog/products | catalog.products.create | YES | CreateProductRequest | ProductResponse | 3.B.2 |
| GET | /catalog/products/{id} | catalog.products.view | — | — | ProductResponse | 3.B.2 |
| PATCH | /catalog/products/{id} | catalog.products.edit | NO | UpdateProductRequest | ProductResponse | 3.B.2 |
| POST | /catalog/products/{id}/publish | catalog.products.edit | YES | — | ProductResponse | 3.B.2 |
| POST | /catalog/products/{id}/archive | catalog.products.edit | YES | ArchiveProductRequest | ProductResponse | 3.B.2 |

### Variants

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| POST | /catalog/variants/search | catalog.variants.view | NO | SearchVariantsRequest | PageResponse&lt;VariantSummary&gt; | 3.B.3, 3.A.2 |
| POST | /catalog/products/{productId}/variants | catalog.variants.create | YES | CreateVariantBatchRequest | List&lt;VariantResponse&gt; | 3.B.3 |
| GET | /catalog/variants/{id} | catalog.variants.view | — | — | VariantResponse | 3.B.3 |
| GET | /catalog/variants/by-barcode/{barcode} | catalog.variants.view | — | — | VariantResponse | 3.A.1 |
| GET | /catalog/variants/by-sku/{sku} | catalog.variants.view | — | — | VariantResponse | (many) |
| PATCH | /catalog/variants/{id} | catalog.variants.edit | NO | UpdateVariantRequest | VariantResponse | 3.B.3 |
| POST | /catalog/variants/{id}/deactivate | catalog.variants.edit | YES | DeactivateVariantRequest | VariantResponse | 3.B.3 |
| POST | /catalog/variants/{id}/reactivate | catalog.variants.edit | YES | — | VariantResponse | 3.B.3 |

### Attributes

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| GET | /catalog/attributes | catalog.attributes.view | — | — | List&lt;AttributeResponse&gt; | 3.B.5 |
| POST | /catalog/attributes | catalog.attributes.create | YES | CreateAttributeRequest | AttributeResponse | 3.B.5 |
| GET | /catalog/attributes/{id} | catalog.attributes.view | — | — | AttributeResponse | 3.B.5 |
| PATCH | /catalog/attributes/{id} | catalog.attributes.edit | NO | UpdateAttributeRequest | AttributeResponse | 3.B.5 |
| POST | /catalog/attributes/{id}/values | catalog.attributes.edit | YES | AddAttributeValueRequest | AttributeResponse | 3.B.5 |
| POST | /catalog/attributes/{id}/deactivate | catalog.attributes.edit | YES | — | AttributeResponse | 3.B.5 |

### Brands

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| GET | /catalog/brands | catalog.brands.view | — | — | List&lt;BrandResponse&gt; | (many) |
| POST | /catalog/brands | catalog.brands.create | YES | CreateBrandRequest | BrandResponse | 3.B.2 |
| GET | /catalog/brands/{id} | catalog.brands.view | — | — | BrandResponse | — |
| PATCH | /catalog/brands/{id} | catalog.brands.edit | NO | UpdateBrandRequest | BrandResponse | — |

### Categories

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| GET | /catalog/categories | catalog.categories.view | — | — | List&lt;CategoryResponse&gt; (tree) | (many) |
| POST | /catalog/categories | catalog.categories.create | YES | CreateCategoryRequest | CategoryResponse | — |
| PATCH | /catalog/categories/{id} | catalog.categories.edit | NO | UpdateCategoryRequest | CategoryResponse | — |
| POST | /catalog/categories/{id}/archive | catalog.categories.edit | YES | — | CategoryResponse | — |

### Missing Items

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| GET | /catalog/missing-items | catalog.missing_items.view | — | — | List&lt;MissingItemResponse&gt; | 3.B.6 |
| POST | /catalog/missing-items | catalog.missing_items.create | YES | CreateMissingItemRequest | MissingItemResponse | 3.A.2 |
| POST | /catalog/missing-items/{id}/resolve | catalog.missing_items.resolve | YES | ResolveMissingItemRequest | MissingItemResponse | 3.B.6 |
| POST | /catalog/missing-items/{id}/reject | catalog.missing_items.resolve | YES | RejectMissingItemRequest | MissingItemResponse | 3.B.6 |

---

## 3. Pricing

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| GET | /pricing/price-lists | pricing.lists.view | — | — | List&lt;PriceListResponse&gt; | 3.B.4 |
| POST | /pricing/price-lists | pricing.lists.create | YES | CreatePriceListRequest | PriceListResponse | 3.B.4 |
| GET | /pricing/price-lists/{id} | pricing.lists.view | — | — | PriceListResponse | 3.B.4 |
| POST | /pricing/price-lists/{id}/activate | pricing.lists.edit | YES | — | PriceListResponse | 3.B.4 |
| POST | /pricing/price-lists/{id}/archive | pricing.lists.edit | YES | — | PriceListResponse | 3.B.4 |
| POST | /pricing/price-lists/{id}/entries/search | pricing.lists.view | NO | SearchPriceEntriesRequest | PageResponse&lt;PriceEntryResponse&gt; | 3.B.4 |
| PATCH | /pricing/price-lists/{id}/entries | pricing.lists.edit | NO | UpsertPriceEntriesRequest | List&lt;PriceEntryResponse&gt; | 3.B.4 |
| GET | /pricing/store-overrides | pricing.overrides.view | — | — | List&lt;StoreOverrideResponse&gt; | 3.B.4 |
| POST | /pricing/store-overrides | pricing.overrides.edit | YES | UpsertStoreOverrideRequest | StoreOverrideResponse | 3.B.4 |
| POST | /pricing/store-overrides/{id}/revert | pricing.overrides.edit | YES | — | StoreOverrideResponse | 3.B.4 |
| GET | /pricing/resolve | (any with sales/catalog read) | — | (query: variant_id, store_id) | ResolvedPriceResponse | 3.A.1 |
| POST | /pricing/resolve-batch | (any with sales/catalog read) | NO | ResolveBatchRequest | Map&lt;VariantId,ResolvedPrice&gt; | 3.A.1 |

---

## 4. Inventory

### Stock balances

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| POST | /inventory/stock-balances/search | inventory.stock.view | NO | SearchStockBalancesRequest | PageResponse&lt;StockBalanceResponse&gt; | 3.C.1 |
| GET | /inventory/stock-balances/{variantId}/{storeId} | inventory.stock.view | — | (query: fresh?) | StockBalanceResponse | 3.A.5 |

### Movements

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| POST | /inventory/movements/search | inventory.movements.view | NO | SearchMovementsRequest | PageResponse&lt;StockMovementResponse&gt; | 3.C.2 |
| GET | /inventory/movements/{id} | inventory.movements.view | — | — | StockMovementResponse | 3.C.2 |
| GET | /inventory/movements/by-correlation/{correlationId} | inventory.movements.view | — | — | List&lt;StockMovementResponse&gt; | 3.C.2, 3.E.6 |

### Transfers

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| POST | /inventory/transfers/search | inventory.transfers.view | NO | SearchTransfersRequest | PageResponse&lt;TransferSummary&gt; | 3.C.3 |
| POST | /inventory/transfers | inventory.transfers.create_draft | YES | CreateTransferRequest | TransferResponse | 3.C.3 |
| GET | /inventory/transfers/{id} | inventory.transfers.view | — | — | TransferResponse | 3.C.3 |
| PATCH | /inventory/transfers/{id} | inventory.transfers.create_draft | NO | UpdateTransferDraftRequest | TransferResponse | 3.C.3 |
| POST | /inventory/transfers/{id}/abandon | inventory.transfers.create_draft | YES | — | — | 3.C.3 |
| POST | /inventory/transfers/{id}/dispatch | inventory.transfers.dispatch | YES | DispatchTransferRequest | TransferResponse | 3.C.3 |
| POST | /inventory/transfers/{id}/confirm-shipped | inventory.transfers.confirm_shipped | YES | — | TransferResponse | 3.C.3 |
| POST | /inventory/transfers/{id}/receive | inventory.transfers.receive | YES | ReceiveTransferRequest | TransferResponse | 3.C.3 |
| POST | /inventory/transfers/{id}/cancel | inventory.transfers.cancel_dispatched (or cancel_in_transit) | YES | CancelTransferRequest | TransferResponse | 3.C.3 |

### Count sessions

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| POST | /inventory/counts/search | inventory.counts.view | NO | SearchCountsRequest | PageResponse&lt;CountSessionSummary&gt; | 3.C.4 |
| POST | /inventory/counts | inventory.counts.create | YES | CreateCountSessionRequest | CountSessionResponse | 3.C.4 |
| GET | /inventory/counts/{id} | inventory.counts.view | — | — | CountSessionResponse | 3.C.4 |
| PATCH | /inventory/counts/{id} | inventory.counts.create | NO | UpdateCountSessionRequest | CountSessionResponse | 3.C.4 |
| POST | /inventory/counts/{id}/start | inventory.counts.create | YES | — | CountSessionResponse | 3.C.4 |
| PATCH | /inventory/counts/{id}/lines/{lineId} | inventory.counts.count | NO | UpdateCountLineRequest | CountSessionLineResponse | 3.C.4 |
| POST | /inventory/counts/{id}/finalize | inventory.counts.finalize | YES | FinalizeCountRequest | CountSessionResponse | 3.C.4 |
| POST | /inventory/counts/{id}/cancel | inventory.counts.cancel | YES | CancelCountRequest | CountSessionResponse | 3.C.4 |
| GET | /inventory/counts/{id}/movements-during-session | inventory.counts.view | — | — | List&lt;StockMovementResponse&gt; | 3.C.4 |

### Adjustments

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| POST | /inventory/adjustments/search | inventory.adjustments.view | NO | SearchAdjustmentsRequest | PageResponse&lt;AdjustmentSummary&gt; | 3.C.5 |
| POST | /inventory/adjustments | inventory.adjustments.create | YES | CreateAdjustmentRequest | AdjustmentResponse | 3.C.5 |
| GET | /inventory/adjustments/{id} | inventory.adjustments.view | — | — | AdjustmentResponse | 3.C.5 |

---

## 5. Sales (POS + Returns)

### Sales lifecycle

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| POST | /pos/sales | sales.create | YES | CreateSaleRequest | SaleResponse | 3.A.1 |
| GET | /pos/sales/{id} | sales.view | — | — | SaleResponse | 3.A.1 |
| PATCH | /pos/sales/{id} | sales.edit_draft | NO | UpdateSaleRequest | SaleResponse | 3.A.1 |
| POST | /pos/sales/{id}/items | sales.edit_draft | YES | AddSaleLineRequest | SaleLineResponse | 3.A.1 |
| PATCH | /pos/sales/{id}/items/{lineId} | sales.edit_draft | NO | UpdateSaleLineRequest | SaleLineResponse | 3.A.1 |
| POST | /pos/sales/{id}/items/{lineId}/remove | sales.edit_draft | YES | — | — | 3.A.1 |
| POST | /pos/sales/{id}/attach-customer | sales.edit_draft | YES | AttachCustomerRequest | SaleResponse | 3.A.3 |
| POST | /pos/sales/{id}/detach-customer | sales.edit_draft | YES | — | SaleResponse | 3.A.3 |
| POST | /pos/sales/{id}/discount/line | sales.apply_discount | YES | ApplyLineDiscountRequest | SaleResponse | 3.A.4 |
| POST | /pos/sales/{id}/discount/cart | sales.apply_discount | YES | ApplyCartDiscountRequest | SaleResponse | 3.A.4 |
| POST | /pos/sales/{id}/discount/clear | sales.apply_discount | YES | — | SaleResponse | 3.A.4 |
| POST | /pos/sales/{id}/proceed-to-payment | sales.edit_draft | YES | — | SaleResponse | 3.A.5 |
| POST | /pos/sales/{id}/payments | sales.complete | YES | RecordPaymentRequest | PaymentAttemptResponse | 3.A.5 |
| POST | /pos/sales/{id}/payments/{attemptId}/retry-card | sales.complete | YES | RetryCardPaymentRequest | PaymentAttemptResponse | 3.A.6 |
| POST | /pos/sales/{id}/complete | sales.complete | YES | CompleteSaleRequest | SaleResponse | 3.A.5, 3.A.7 |
| POST | /pos/sales/{id}/cancel | sales.cancel_draft | YES | CancelSaleRequest | — | 3.A.1 |
| POST | /pos/sales/{id}/administratively-reverse | sales.admin_reverse | YES | AdminReverseSaleRequest | SaleResponse | (admin) |

### Sales queries (read-only)

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| POST | /sales/search | sales.view | NO | SearchSalesRequest | PageResponse&lt;SaleSummary&gt; | (many) |
| GET | /sales/{id} | sales.view | — | — | SaleResponse | 3.D.3 |
| GET | /sales/{id}/receipt | sales.view | — | — | ReceiptResponse | 3.A.7 |
| GET | /sales/{id}/receipt/pdf | sales.view | — | — | (binary PDF) | 3.A.7 |

### Returns

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| POST | /finance/returns/search | returns.view | NO | SearchReturnsRequest | PageResponse&lt;ReturnSummary&gt; | 3.D.4 |
| POST | /finance/returns | returns.initiate | YES | InitiateReturnRequest | ReturnResponse | 3.D.3 |
| GET | /finance/returns/{id} | returns.view | — | — | ReturnResponse | 3.D.4 |
| PATCH | /finance/returns/{id}/return-lines | returns.process | NO | UpdateReturnLinesRequest | ReturnResponse | 3.D.4 |
| PATCH | /finance/returns/{id}/exchange-lines | returns.exchange | NO | UpdateExchangeLinesRequest | ReturnResponse | 3.D.4 |
| PATCH | /finance/returns/{id}/refund-tender | returns.process | NO | SetRefundTenderRequest | ReturnResponse | 3.D.4 |
| POST | /finance/returns/{id}/finalize | returns.process | YES | FinalizeReturnRequest | ReturnResponse | 3.D.4 |
| POST | /finance/returns/{id}/cancel | returns.process | YES | CancelReturnRequest | ReturnResponse | 3.D.4 |

---

## 6. Purchasing

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| POST | /finance/purchase-invoices/search | purchasing.invoices.view | NO | SearchPurchaseInvoicesRequest | PageResponse&lt;PurchaseInvoiceSummary&gt; | 3.D.1 |
| POST | /finance/purchase-invoices | purchasing.invoices.create | YES | CreatePurchaseInvoiceRequest | PurchaseInvoiceResponse | 3.D.2 |
| GET | /finance/purchase-invoices/{id} | purchasing.invoices.view | — | — | PurchaseInvoiceResponse | 3.D.2 |
| PATCH | /finance/purchase-invoices/{id} | purchasing.invoices.edit_draft | NO | UpdatePurchaseInvoiceDraftRequest | PurchaseInvoiceResponse | 3.D.2 |
| PATCH | /finance/purchase-invoices/{id}/lines | purchasing.invoices.edit_draft | NO | UpdatePurchaseInvoiceLinesRequest | PurchaseInvoiceResponse | 3.D.2 |
| POST | /finance/purchase-invoices/{id}/abandon | purchasing.invoices.edit_draft | YES | — | — | 3.D.2 |
| POST | /finance/purchase-invoices/{id}/commit | purchasing.invoices.commit | YES | CommitPurchaseInvoiceRequest | PurchaseInvoiceResponse | 3.D.2 |
| POST | /finance/purchase-invoices/{id}/reverse | purchasing.invoices.reverse | YES | ReversePurchaseInvoiceRequest | PurchaseInvoiceResponse | 3.D.2 |

---

## 7. Finance (Accounts + Payments + Store Credit)

### Parties (customers + suppliers)

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| POST | /parties/search | parties.view | NO | SearchPartiesRequest | PageResponse&lt;PartySummary&gt; | 3.A.3, 3.D.7 |
| POST | /parties | parties.create | YES | CreatePartyRequest | PartyResponse | 3.A.3 |
| GET | /parties/{id} | parties.view | — | (query: full_phone?) | PartyResponse | 3.D.5, 3.D.6 |
| PATCH | /parties/{id} | parties.edit | NO | UpdatePartyRequest | PartyResponse | 3.D.5 |
| POST | /parties/{id}/deactivate | parties.edit | YES | DeactivatePartyRequest | PartyResponse | 3.D.5 |

### Accounts (customer + supplier)

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| GET | /finance/accounts/{partyId} | finance.accounts.view | — | (query: fresh?) | AccountSummaryResponse | 3.D.5, 3.D.6, 3.A.5 |
| POST | /finance/accounts/{partyId}/movements/search | finance.accounts.view | NO | SearchAccountMovementsRequest | PageResponse&lt;AccountMovementResponse&gt; | 3.D.5, 3.D.6 |

### Customer-facing semantic routes (mirror to accounts)

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| GET | /finance/customer-accounts/{partyId} | finance.accounts.view | — | — | AccountSummaryResponse (role=CUSTOMER) | 3.D.5 |
| GET | /finance/supplier-accounts/{partyId} | finance.accounts.view | — | — | AccountSummaryResponse (role=SUPPLIER) | 3.D.6 |

### Payments

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| POST | /finance/payments/search | finance.payments.view | NO | SearchPaymentsRequest | PageResponse&lt;PaymentSummary&gt; | 3.D.7 |
| POST | /finance/payments | finance.collect_customer_payment OR finance.pay_supplier | YES | CreatePaymentRequest | PaymentResponse | 3.D.7 |
| GET | /finance/payments/{id} | finance.payments.view | — | — | PaymentResponse | 3.D.7 |

### Customer-facing semantic routes (mirror to payments)

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| GET | /finance/customer-payments | finance.payments.view | — | — | PageResponse&lt;PaymentSummary&gt; (direction=COLLECT) | 3.D.7 |
| GET | /finance/supplier-payments | finance.payments.view | — | — | PageResponse&lt;PaymentSummary&gt; (direction=PAY) | 3.D.7 |

### Store credit

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| GET | /finance/store-credit/{partyId} | finance.accounts.view | — | — | StoreCreditBalanceResponse | 3.D.5 |
| POST | /finance/store-credit/{partyId}/movements/search | finance.accounts.view | NO | SearchStoreCreditMovementsRequest | PageResponse&lt;AccountMovementResponse&gt; | 3.D.5 |

---

## 8. Cash Register

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| GET | /cash-register/current | cashregister.view_current_session | — | (query: store_id, register_id) | CashRegisterSessionResponse \| null | 3.E.1, 3.A.1 |
| POST | /cash-register/open | cashregister.open | YES | OpenCashRegisterRequest | CashRegisterSessionResponse | 3.E.1 |
| POST | /cash-register/sessions/search | cashregister.view | NO | SearchCashRegisterSessionsRequest | PageResponse&lt;CashRegisterSessionSummary&gt; | (admin) |
| GET | /cash-register/sessions/{id} | cashregister.view | — | — | CashRegisterSessionResponse | 3.E.2 |
| GET | /cash-register/sessions/{id}/summary | cashregister.view | — | — | SessionSummaryResponse | 3.E.2 |
| POST | /cash-register/sessions/{id}/close | cashregister.close | YES | CloseCashRegisterRequest | CashRegisterSessionResponse | 3.E.2 |
| POST | /cash-register/sessions/{id}/force-close | cashregister.force_close_orphan | YES | ForceCloseSessionRequest | CashRegisterSessionResponse | 3.E.1 |
| GET | /cash-register/sessions/{id}/z-report | cashregister.view_z_reports | — | — | ZReportResponse | 3.E.2 |
| GET | /cash-register/sessions/{id}/z-report/pdf | cashregister.view_z_reports | — | — | (binary PDF, deterministic) | 3.E.2 |
| POST | /cash-register/sessions/{id}/z-report/reprint | cashregister.reprint_z_report | YES | — | ZReportResponse | 3.E.2 |
| POST | /cash-register/sessions/{id}/movements/search | cashregister.view | NO | SearchCashMovementsRequest | PageResponse&lt;CashMovementResponse&gt; | 3.E.2 |

---

## 9. Reporting (Reports + Audit + Async export)

### Reports

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| GET | /reports | (any with reports.* perm) | — | — | List&lt;ReportMetadata&gt; | 3.E.5 |
| POST | /reports/sales-summary | reports.view_sales | NO | SalesSummaryQuery | SalesSummaryResponse | 3.E.5 |
| POST | /reports/stock-valuation | reports.view_stock_valuation | NO | StockValuationQuery | StockValuationResponse | 3.E.5 |
| POST | /reports/top-selling | reports.view_sales | NO | TopSellingQuery | TopSellingResponse | 3.E.5 |
| POST | /reports/customer-aging | reports.view_customer_aging | NO | CustomerAgingQuery | CustomerAgingResponse | 3.E.5 |
| POST | /reports/markup-analysis | reports.view_markup | NO | MarkupAnalysisQuery | MarkupAnalysisResponse | 3.E.5 |

### CSV export (async)

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| POST | /reports/sales-summary/export | reports.export_csv | YES | SalesSummaryQuery | ExportJobResponse (202) | 3.E.5 |
| POST | /reports/stock-valuation/export | reports.export_csv | YES | StockValuationQuery | ExportJobResponse (202) | 3.E.5 |
| POST | /reports/top-selling/export | reports.export_csv | YES | TopSellingQuery | ExportJobResponse (202) | 3.E.5 |
| POST | /reports/customer-aging/export | reports.export_csv | YES | CustomerAgingQuery | ExportJobResponse (202) | 3.E.5 |
| POST | /reports/markup-analysis/export | reports.export_csv | YES | MarkupAnalysisQuery | ExportJobResponse (202) | 3.E.5 |
| POST | /admin/audit-log/export | audit.export_csv | YES | SearchAuditLogRequest | ExportJobResponse (202) | 3.E.6 |
| GET | /jobs/{jobId} | (any) | — | — | ExportJobStatusResponse | — |
| GET | /jobs/{jobId}/download | (any with originating perm) | — | — | (binary) | — |

### Audit log

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| POST | /admin/audit-log/search | audit.view | NO | SearchAuditLogRequest | PageResponse&lt;AuditEventResponse&gt; | 3.E.6 |
| GET | /admin/audit-log/{id} | audit.view | — | — | AuditEventDetailResponse | 3.E.6 |
| GET | /admin/audit-log/by-correlation/{correlationId} | audit.view | — | — | List&lt;AuditEventResponse&gt; (timeline) | 3.E.6 |

---

## 10. Cross-cutting

### Health + observability (operational)

| Method | Path | Perm | Idem | Req | Resp | Screen |
|---|---|---|---|---|---|---|
| GET | /health | (public) | — | — | HealthResponse | (ops) |
| GET | /health/ready | (public) | — | — | ReadinessResponse | (ops) |

---

## Summary statistics

| Module | Endpoints |
|---|---|
| Identity (auth + admin + tenant + stores) | 24 |
| Catalog (products + variants + attributes + brands + categories + missing items) | 30 |
| Pricing | 12 |
| Inventory (balances + movements + transfers + counts + adjustments) | 28 |
| Sales (POS + sales queries + returns) | 25 |
| Purchasing | 8 |
| Finance (parties + accounts + payments + store credit) | 17 |
| Cash Register | 11 |
| Reporting (reports + exports + audit) | 17 |
| Cross-cutting | 2 |
| **Total** | **~174** |

(Higher than the ~120 initial estimate because each lifecycle action gets its own endpoint per PATCH-vs-action convention. Trade-off accepted; each endpoint is single-purpose and idempotency-safe.)

---

## Sprint-order endpoint allocation

For Phase 7 implementation sprints (bottom-up dependency order):

| Sprint | Module | Endpoints | Critical paths |
|---|---|---|---|
| 1 | shared | 0 (no API) | Money, Percentage, IDs, error model |
| 2 | identity | 24 | /auth/login, /me, basic user admin |
| 3 | catalog | 30 | products + variants + attributes (largest catalog surface) |
| 4a | pricing | 12 | /pricing/resolve (POS critical path) |
| 4b | inventory | 28 | stock-balances search, movements, adjustments |
| 5 | purchasing | 8 | invoice DRAFT → COMMITTED flow |
| 6 | sales | 25 | POS sale lifecycle (largest single surface) |
| 7a | finance | 17 | accounts, payments, store credit |
| 7b | cashregister | 11 | session open/close + Z report |
| 8 | reporting | 17 | 5 reports + audit log + CSV export |

---

## Conventions reference

Detailed in `05-api-conventions.md`. Highlights:

- **No DELETE methods**: all soft state transitions via `POST /{id}/{action}`
- **PATCH vs Action**: PATCH for field mutation, POST action for lifecycle transition
- **X-Idempotency-Key required** on every POST create + POST {id}/{action} endpoint
- **X-Correlation-Id** auto-generated server-side if absent; always echoed in response
- **RFC 7807 problem+json** for all error responses
- **errorCode** uses module-namespaced prefix (`INV_`, `SALE_`, `FIN_`, etc.)
- **Pagination** consistent shape with optional `total_items` for performance
- **Manager PIN override** via `/auth/manager-pin-verify` + override_token in subsequent request
