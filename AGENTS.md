# TransporteZC Admin — Agent context

## Stack

Vue 3 SFC + TS 6 + Vite 8 + Pinia + Vue Router + PrimeVue 4 Aura (light only) + Tailwind 3 + Supabase (Auth, DB, RPC) + Chart.js.

Fonts: **Inter** (Google Fonts in `index.html`), **Material Symbols Outlined** (icon font). Vite alias `@` → `./src`.

## Commands

```sh
npm run dev           # Vite dev server (SSL via basicSsl, host 0.0.0.0)
npm run dev:debug     # vite --debug --host
npm run build         # run-p type-check build-only
npm run type-check    # vue-tsc --build only (no test suite)
npm run preview       # vite preview
npm run import-data   # SUPABASE_IMPORT=true node scripts/import-data.mjs
npm run backup-db     # node scripts/backup-db.mjs
bash scripts/deploy.sh <domain> <ssh_user> <server_ip> [pem_file]  # Build + rsync to nginx, generates hardened nginx config
```

No linter, formatter, or test framework.

## Architecture

```
src/
├── main.ts                  # Entry: Pinia, Router, PrimeVue Aura (darkModeSelector:false), ToastService
│                            # Globals registered: Button, Avatar, DatePicker, InputText, Password, Toast
├── router/index.ts          # 10 routes:
│                            #   /login (auth), / (requiresAuth) →
│                            #     ""→Home
│                            #     /clientes, /unidades, /recargas, /movimientos
│                            #     /configuracion (tab: Parámetros)
│                            #     /configuracion/horarios, /configuracion/usuarios
│                            #     /analisis-mensual
│                            # beforeEach: initAuth(), redirect if unauthenticated
├── stores/
│   ├── authStore.ts         # Session, login/logout, user profile. login() accepts email OR username
│   ├── unitStore.ts         # list CRUD via manage_unit RPC
│   ├── clientStore.ts       # list CRUD via manage_client RPC
│   ├── companyStore.ts      # fetchCompany, saveCompany via direct table upsert
│   ├── horarioStore.ts      # fetchAll, create, update, remove via manage_horario RPC
│   ├── usuarioStore.ts      # fetchAll, create, update, remove via manage_profile RPC
│   ├── rechargeStore.ts     # Paginated list + stats + approve/reject via RPCs
│   ├── ticketStore.ts       # UNUSED (preserve)
│   └── solicitudeStore.ts   # UNUSED (preserve)
├── services/
│   ├── supabaseClient.ts    # Singleton — do not modify
│   ├── unitService.ts       # manage_unit RPC (create/update/delete) + direct table select
│   ├── clientService.ts     # manage_client RPC (create/update/delete) + direct table select
│   ├── rechargeService.ts   # get_recharges_paginated, get_recharge_stats, process_recharge_status RPCs
│   ├── transactionService.ts # Direct table select with explicit cols, joins, range pagination, sort whitelist; also exportTransactions() for CSV
│   ├── companyService.ts    # Single-row company table get/upsert
│   ├── horarioService.ts    # CRUD via manage_horario RPC
│   ├── usuarioService.ts    # CRUD via manage_profile RPC
│   └── ticketsService.ts    # getMovimientosUnificado, getSaldoDisponible, getClienteByUid, procesarPago, chargeTicketsBulk
├── layouts/
│   ├── AuthLayout.vue       # Passthrough for /login
│   └── AppLayout.vue        # Sidebar fixed lg+/overlay mobile, topbar, <router-view>
│                            # Configuración is an expandable submenu (Parámetros, Horarios, Usuarios)
│                            # auto-expands when route starts with /configuracion
├── pages/
│   ├── Login.vue            # Split branding/form, native inputs (not PrimeVue)
│   ├── Home.vue             # Dashboard with 4 KPI cards (StatCard), ReservasTable, WeeklyChart, RecentMovements
│   │                        # Parallel RPC calls via Promise.all, ReservaDetailDialog for schedule detail
│   ├── Clientes.vue         # CRUD datatable + dialog, uses clientStore; each row has movements modal
│   ├── Unidades.vue         # CRUD responsive table/cards, uses unitStore
│   ├── HistorialRecargas.vue # Paginated list + stats + approve/reject, uses rechargeStore + FiltroRango
│   ├── HistorialMovimientos.vue # Lazy DataTable + server-side pagination/sort/filter, uses transactionService
│   │                        # Exportar Datos button exports ALL filtered records as CSV
│   ├── Configuracion.vue    # 3 cards: info empresa, parámetros financieros, info bancaria
│   │                        # Admin-gated (inputs disabled, save hidden for non-admin)
│   ├── Horarios.vue         # Full CRUD table, search, sort, pagination, dialog, admin-gated
│   ├── Usuarios.vue         # Full CRUD table/cards, name/email/password/role, admin-gated
│   └── AnalisisMensual.vue  # Monthly report with year/month selector, KPI cards, daily chart, top clients table
│                            # Export CSV for daily breakdown and top clients
├── components/
│   ├── dashboard/
│   │   ├── StatCard.vue     # Reusable KPI card: icon, label, value, trend, subtitle, progress bar, accent variant, loading skeleton
│   │   ├── ReservasTable.vue # Daily reservations from transactions grouped by shedule, date picker, emits view-detail
│   │   ├── WeeklyChart.vue  # Horizontal bar chart (Chart.js + PrimeVue Chart) for last 7 days, links to AnalisisMensual
│   │   ├── RecentMovements.vue # Unified activity feed (transactions + recharges), CSV export
│   │   └── ReservaDetailDialog.vue # Modal showing reservations for a specific shedule+date
│   ├── FiltroRango.vue      # Shared date-range filter component (used by Recargas, HistorialMovimientos)
│   ├── FiltroMovimientos.vue # UNUSED
│   ├── QrScanner.vue        # UNUSED
│   └── FileUploadZone.vue   # UNUSED
├── composables/useScanner.ts # UNUSED
├── utils/
│   ├── formatters.ts        # formatDate, formatDateTime, formatCurrency, formatCurrencyWithSign, formatCount — es-AR locale
│   └── exportCsv.ts         # downloadCSV(data, filename, columns) — BOM UTF-8 for Excel compat
└── assets/
    ├── main.css             # Tailwind directives + PrimeVue overrides
    └── variables.css        # Design tokens
```

## Key backend patterns

- **All writes** go through PostgreSQL RPCs via `supabase.rpc()`. No Edge Functions.
- **`manage_unit(p_action, p_unit_id, p_name, p_number, p_plate, p_status, p_driver)`** → `{success, data?, message?}`.
- **`manage_client(p_action, ...)`** — same pattern; email syncs back to `profiles` and `auth.users`.
- **`manage_horario(p_action, p_id, p_code, p_shudle, p_status)`** — same CRUD pattern; `SECURITY DEFINER` with explicit `is_admin()` guard.
- **`manage_profile(p_action, p_id, p_name, p_email, p_password, p_role)`** — manages `profiles` table; email changes sync to `public.clients`.
- **Recharge RPCs**: `get_recharges_paginated(p_page, p_per_page, p_status, p_date_from, p_date_to, p_method)` → `{data, total}`, `get_recharge_stats()` → `{pending, rejected, approved, total_amount}`, `process_recharge_status(p_recharge_id, p_action, p_approved_by)` → `{success, message?}`.
- **Auth RPCs**: `get_email_by_username(username_input)` → email string, `get_complete_user_profile(p_uuid, p_email)` → `ClientProfile`.
- **Transactions**: direct `supabase.from("transactions").select(...)` with explicit columns, joins to `clients(name)` and `units(name)`, range-based pagination, `ALLOWED_COLUMNS` sort whitelist, ISO-date regex filters. `exportTransactions()` returns all matching rows without pagination.
- **`company` table** is single-row; `select('*').maybeSingle()` for reads, `upsert()` for writes.
- **Dashboard RPCs** (all `SECURITY DEFINER`):
  - `get_dashboard_kpis()` → JSON with debtors_total/debtors_count, active_clients, total_clients, recharges_today, recharges_amount_today, transactions_today
  - `get_daily_reservas(p_date)` → TABLE(shedule VARCHAR, count BIGINT) — transactions grouped by shedule for a date
  - `get_weekly_flow()` → TABLE(day DATE, count BIGINT, total_amount NUMERIC) — last 7 days
  - `get_recent_movements(p_limit)` → TABLE(id, type, description, amount, created_at, client_name) — UNION of transactions + recharges
  - `get_reservas_detail(p_date, p_shedule)` → TABLE(id, client_name, amount, created_at) — transaction details for a schedule
  - `get_monthly_summary(p_year, p_month)` → JSON with total_transactions, total_recharges, amounts, active_clients, daily_data[], top_clients[]

## PrimeVue component registration

| Globally registered (`main.ts`) | Must import per-file                 |
|--------------------------------|--------------------------------------|
| Button, Avatar, DatePicker, InputText, Password, Toast | DataTable, Column, Menu, Select, Textarea, Chart, etc. |
| ToastService (app.use)         | `useToast` from `primevue/usetoast`   |

## Key details

- **`noUncheckedIndexedAccess: true`** in tsconfig — use optional chaining/type guards on array/object access.
- **Design tokens** in `tailwind.config.cjs` (custom colors, spacing, font sizes). No Tailwind plugins.
- **Status convention**: clients `'0'` = Activo, `'1'` = Inactivo; recharges `0` = pendiente, `1` = aprobado, `2` = rechazado.
- **`design/`** has reference HTML files for visual matching (login, home, clients, units, recargas, movimientos, config).
- **SQL files** (`*.sql` in root) define DB schema, RPCs, triggers, policies — deploy to Supabase separately.
  - `supabase_company_rls.sql` — RLS + policies for `company` table
  - `supabase_horario.sql` — `horario` table, seed data, RLS, `manage_horario` RPC
  - `supabase_usuarios.sql` — `profiles.name` migration + partial unique index + `manage_profile` RPC with email sync to clients
  - `supabase_dashboard.sql` — 6 dashboard RPCs (kpis, reservas, weekly, movements, reservas_detail, monthly_summary)
  - `supabase_backup_logic.sql` — all legacy RPCs including `manage_client` with back-sync to profiles/auth.users
  - `supabase-policies.sql` — canonical `is_admin()` via `auth.uid()`
  - `dbsupabase.sql` — `clients`, `recharge`, `transactions` table schemas
- **`env.d.ts`** just has `/// <reference types="vite/client" />`.
- **`is_admin()`** function exists in public schema — checks `auth.uid()` against `profiles.id WHERE role = 'admin'`.
- **CSV export** uses `downloadCSV()` from `@/utils/exportCsv` — adds BOM for Excel, escapes commas/quotes.

## Admin gating

- Frontend: inputs disabled, save buttons hidden for non-admin (`auth.user?.role !== 'admin'`)
- Backend: RLS policies + `SECURITY DEFINER` RPCs with explicit `IF NOT is_admin()` guards
- Covers: Configuracion, Horarios, Usuarios, manage_* RPCs, company RLS

## Gotchas

- `.env` has real Supabase credentials and is **committed to git**. Don't leak or add secrets.
- `.env.local` is gitignored; holds `SUPABASE_DB_URL` for `import-data` only.
- `import.meta.env.VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` read from `.env`.
- Node `^20.19.0 || >=22.12.0` required.
- TypeScript ~6.0.0 — some tooling may not be compatible.
- Dev server at `https://localhost:5173/` (TLS required by browser APIs like QR scanner).
- Tailwind JIT requires complete class names (no dynamic concatenation like `bg-${color}`).
- After any change, run `npm run type-check` to verify (no test suite).
- `recharge` table columns use camelCase (`"createAt"`, `"idclient"`, `"createBy"`) — must quote in SQL.
- `profiles.name` has a partial unique index; backfilled from `raw_user_meta_data->>'user_name'`.
- Email sync between `profiles` and `clients` is bi-directional via both `manage_profile` and `manage_client` RPCs.
