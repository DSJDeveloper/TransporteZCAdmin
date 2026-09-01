# TransporteZC Admin — Agent Context & Rules

## 🎯 Perfil Tecnológico y Stack
* **Frontend:** Vue 3 SFC + TypeScript 6 + Vite 8 + Pinia + Vue Router.
* **UI & Estilos:** PrimeVue 4 Aura (Skins: light only, `darkModeSelector: false`) + Tailwind 3.
* **Backend:** Supabase (Auth, DB, RPC). **Sin Edge Functions**.
* **Gráficos & Fuentes:** Chart.js (vía PrimeVue Chart), Inter (Google Fonts), Material Symbols Outlined.
* **Alias de rutas:** `@` → `./src`.

---

### 🗄️ Estructura de Base de Datos y Código SQL (Supabase)
El estado de la base de datos, los esquemas de las tablas y el código de las funciones RPC se gestionan a través de los siguientes archivos canónicos en el proyecto:

* **Estructura Base (`supabase_backup_schema.sql`):** Archivo central de referencia para el esquema de datos. Contiene todas las sentencias `CREATE TABLE`, tipos de datos, llaves primarias/foráneas y restricciones de las tablas del sistema (como `clients`, `recharge`, `transactions`, `company`, `horario`, `stops`, `route_stops`, `tickets`, etc.).
* **Lógica del Servidor y Funciones (`supabase_backup_logic.sql`):** Archivo central de referencia para la programación en el backend. Contiene todos los Procedimientos Almacenados (RPCs) escritos en PL/pgSQL, triggers, políticas RLS y funciones de control de acceso.


## 👥 Roles del Asistente (Skills Integrados)

Cuando proceses una solicitud para este proyecto, debes actuar bajo la combinación de estos 4 perfiles:
1.  **Auditor de Ciberseguridad (Prioridad Alta):** Obsesionado con el principio de menor privilegio, inyecciones SQL en PL/pgSQL y la verificación de que las mutaciones e información sensible pasen por validaciones estrictas en el servidor.
2.  **Arquitecto Supabase/PostgreSQL:** Experto en escribir código nativo SQL para migraciones, funciones RPC eficientes con `SECURITY DEFINER` y el manejo correcto del tipado de datos en Postgres.
3.  **Desarrollador Senior Vue 3 & TS:** Especialista en Composition API (`<script setup>`), tipado estricto con `noUncheckedIndexedAccess: true`, y desacoplamiento de lógica de negocio (Stores/Services) de la capa visual.
4.  **Diseñador UI con PrimeVue:** Diseñador meticuloso que explota los componentes nativos de PrimeVue 4 Aura, asegurando layouts limpios mediante utilidades de Tailwind y un manejo fluido de estados (*loading*, *skeletons*, *empty states*).

---

## 🔒 REGLAS CRÍTICAS DE SEGURIDAD (Migración 2026-06-02)

> ⚠️ **PROHIBICIÓN ABSOLUTA:** Queda totalmente prohibido el uso de lecturas o escrituras directas a tablas mediante la API de Supabase en el frontend. No utilices `supabase.from('tabla').select()`, `.insert()`, `.update()`, o `.delete()`.
>
> **La ÚNICA excepción permitida por diseño es `companyService.ts`** para la tabla `company` (lectura pública).

### Lineamientos de Acceso a Datos:
* **Lecturas y Escrituras:** Deben realizarse **exclusivamente** invocando funciones RPC mediante `supabase.rpc('nombre_funcion', { ... })`.
* **Seguridad en Postgres:** Toda nueva función RPC que requiera validación de identidad o rol debe incorporar explícitamente el guardián `is_admin()` en el cuerpo del SQL si es una operación administrativa, o validar que `auth.uid()` coincida con el registro afectado.
* **Rol Supervisor:** El sistema soporta los roles `admin`, `supervisor`, `student`, `driver`. El supervisor tiene los mismos permisos CRUD que el admin pero su visibilidad está limitada a las rutas asignadas en la tabla `user_routes`. Las RPCs de lectura filtran usando `get_current_user_route_ids()`, y las de escritura validan que el `cliente/unidad` pertenezca a una ruta del supervisor. Usa `is_admin_or_supervisor()` en operaciones que apliquen a ambos roles.

---

## 🛠️ Convenciones de Código y Arquitectura

### 🛡️ TypeScript Estricto
* Está activo `noUncheckedIndexedAccess: true`. Cada vez que accedas a elementos de un Array o propiedades dinámicas de un Objeto, **debes usar optional chaining (`?.`) o bloques de guarda/validación de tipo**.

### 🎨 Frontend & UI (PrimeVue + Tailwind)
* **Registro de Componentes:** Verifica la tabla de registro antes de añadir imports:
  * **Globales (`main.ts`):** `Button`, `Avatar`, `DatePicker`, `InputText`, `Password`, `Toast`. No los importes en los componentes.
  * **Locales (Importar por archivo):** `DataTable`, `Column`, `Menu`, `Select`, `Textarea`, `Chart`, etc.
* **Estilos:** Usa clases de utilidad puras de Tailwind 3. **No utilices concatenación dinámica de clases** (ej. `bg-${color}`). El compilador JIT requiere nombres de clases completos.
* **Estructura del Componente:** Sigue el patrón SFC con `<script setup lang="ts">`, seguido de `<template>` y `<style>`.
* **Composables de Diálogo:** Usa `useDialog<T>()` y `useConfirmDialog()` de `@/composables/useDialog.ts`. Los diálogos usan **Teleport a `<body>`** con overlay `bg-black/30 backdrop-blur-sm`, NO PrimeVue Dialog.

### 🗄️ Base de Datos y Formatos de Datos
* **Nombres de Columnas:** Ten cuidado con la tabla `recharge`. Sus columnas usan **camelCase** (`"createAt"`, `"idclient"`, `"createBy"`). En código SQL debes escribirlas entre comillas dobles (ej. `SELECT "createAt" FROM recharge`).
* **Formatos Regionales:** Todas las transformaciones visuales de fechas y monedas deben delegarse a los formateadores de `@/utils/formatters.ts` que utilizan el locale `es-AR`.
* **Exportación de Datos:** Para descargas CSV, utiliza siempre `downloadCSV()` de `@/utils/exportCsv`, la cual inyecta el BOM UTF-8 para garantizar la compatibilidad con Microsoft Excel.
* **RLS Policy Re-creation:** Toda migración SQL que cree políticas RLS **debe** ejecutar `DROP POLICY IF EXISTS "nombre_policy" ON "tabla"` antes de `CREATE POLICY` para garantizar idempotencia.


## 📄 Estándar de Generación de Reportes PDF

Cada vez que se solicite la creación o modificación de componentes, servicios o utilidades para generar reportes y listados en PDF, el código debe maquetarse siguiendo estrictamente este manual de estilo estándar:

### 1. Estructura Base & Layout
* **Header:** Título del documento alineado a la izquierda (`align: 'left'`). Fecha de generación alineada a la derecha (`align: 'right'`).
* **Divider:** Una línea divisoria horizontal limpia inmediatamente debajo del encabezado.
* **Footer:** Número de página centrado en el formato estricto: `'Página X de Y'`.

### 2. Formato de Tablas y Datos
* **Bordes:** Estilo limpio con bordes delgados.
* **Header Row:** Fondo gris claro (`#f2f2f2`) con texto en negrita (`bold`).
* **Zebra Striping:** Filas alternas con un ligero sombreado (un fondo sutil para mejorar la legibilidad en listas largas).

### 3. Tipografía y Escala de Fuentes (Helvetica / Arial)
* **Títulos Principales:** `16pt` (Negrita / Bold).
* **Subtítulos / Secciones:** `12pt` (Negrita / Bold).
* **Texto Base / Datos de Tablas:** `10pt` (Regular).

---

## 📝 Reglas de Documentación (Ahorro de Tokens & Estándar)

Para optimizar la ventana de contexto y mantener consistencia, **todo código generado debe ser auto-documentado en INGLÉS** de forma ultra-concisa siguiendo estas directrices:

### 1. Funciones TypeScript / Composables / Servicios
* Utiliza bloques **JSDoc estándar** únicamente para describir los parámetros, el retorno y una breve línea del propósito.
* **Ejemplo requerido:**
  ```typescript
  /**
   * @description Fetches paginated transactions with strict sorting whitelist.
   * @param {number} page - Current page number (1-indexed).
   * @param {string} sortBy - Allowed columns: 'created_at', 'amount'.
   * @returns {Promise<TransactionResult>} Paginated database response.
   */
  export async function getTransactions(page: number, sortBy: string) { ... }
  ```

---

## 📋 Convenciones de Migraciones SQL

Cada script en `scripts/` sigue un patrón estándar:

1. **Header commentado** con fecha, nombre descriptivo y propósito.
2. **`DROP ... IF EXISTS`** antes de `CREATE` para tablas, constraints, políticas y funciones con firma específica.
3. **`DROP POLICY IF EXISTS "nombre" ON "tabla"`** antes de cada `CREATE POLICY` para idempotencia.
4. **`CREATE OR REPLACE FUNCTION`** con `SECURITY DEFINER` para todas las RPCs.
5. **`DROP FUNCTION IF EXISTS public.funcion(firma)`** antes de `CREATE OR REPLACE` cuando la firma puede cambiar.
6. **RLS habilitado** en todas las tablas nuevas con `ALTER TABLE ... ENABLE ROW LEVEL SECURITY`.

---

## 🗂️ Mapa de Archivos Canónicos

### 📄 Páginas (`src/pages/`)
| Página | Ruta | Admin-only |
|---|---|---|
| `Home.vue` | `/` | No |
| `Clientes.vue` | `/clientes` | No |
| `Unidades.vue` | `/unidades` | No |
| `HistorialRecargas.vue` | `/recargas` | No |
| `HistorialMovimientos.vue` | `/movimientos` | No |
| `AnalisisMensual.vue` | `/analisis-mensual` | No |
| `Configuracion.vue` | `/configuracion` | Sí |
| `InfoBancaria.vue` | `/configuracion/info-bancaria` | Sí |
| `Horarios.vue` | `/configuracion/horarios` | No |
| `Stops.vue` | `/configuracion/paradas` | No |
| `Rutas.vue` | `/configuracion/rutas` | No |
| `Carreras.vue` | `/configuracion/carreras` | Sí |
| `Usuarios.vue` | `/configuracion/usuarios` | Sí |

### 🔧 Servicios (`src/services/`)
| Servicio | Tabla RPC | Notas |
|---|---|---|
| `auth` (authStore) | `get_complete_user_profile` | Login, sesión, initAuth |
| `clientService.ts` | `manage_client`, `get_clients_paginated` | CRUD + paginación; `photo_url` + `email` |
| `unitService.ts` | `manage_unit`, `get_units_paginated` | CRUD + paginación |
| `rechargeService.ts` | `get_recharges_paginated`, `get_recharge_by_id`, `processRechargeStatus` | Filtros `p_search`, paginación, `DetalleRecargaModal` |
| `ticketsService.ts` | `get_movimientos_unificado`, `charge_tickets_bulk`, `add_tickets_to_client` | Devuelve `{ history, balance }` |
| `transactionService.ts` | `get_transactions_paginated`, `get_transactions_export` | Historial de movimientos |
| `routeService.ts` | `manage_route` | CRUD de rutas |
| `horarioService.ts` | `manage_horario` | CRUD de horarios |
| `routeHorarioService.ts` | `manage_route_horario` | N:N ruta↔horario |
| `stopService.ts` | `manage_stop` | CRUD de paradas (list/create/update/delete) |
| `routeStopService.ts` | `manage_route_stop`, `get_stops_by_route` | N:N ruta↔parada con precio y orden |
| `careerService.ts` | `manage_career` | CRUD de carreras |
| `companyService.ts` | `company` (tabla directa) | **ÚNICA excepción** a la regla de RPC |
| `bankInfoService.ts` | `get_bank_info` | Info bancaria |
| `usuarioService.ts` | `manage_profile` | CRUD de usuarios; `password` en updates |
| `userRouteService.ts` | `get_user_routes`, `manage_user_routes` | Asignación de rutas a supervisores |
| `solicitudeService.ts` | `manage_solicitude` | Solicitudes |

### 🏪 Stores (`src/stores/`)
| Store | Servicio | Notas |
|---|---|---|
| `authStore.ts` | auth | `UserRole` incluye `supervisor`. `login()` setea `initialized`. `initAuth()` early-returns si ya inicializado. |
| `clientStore.ts` | clientService | Error ref con mensaje real |
| `unitStore.ts` | unitService | Error ref con mensaje real |
| `rechargeStore.ts` | rechargeService | Filtros pasan al servicio directamente |
| `ticketStore.ts` | ticketsService | `cobrarTicketsBulk`, `addTickets` |
| `routeStore.ts` | routeService | CRUD |
| `horarioStore.ts` | horarioService | CRUD |
| `routeHorarioStore.ts` | routeHorarioService | `assign`, `remove`, `getHorarios` |
| `stopStore.ts` | stopService | CRUD |
| `routeStopStore.ts` | routeStopService | `stopsByRoute` (Record por route ID), `fetchByRoute`, `assign`, `update`, `remove`, `getStops` |
| `careerStore.ts` | careerService | CRUD |
| `bankInfoStore.ts` | bankInfoService | Fetch all |
| `usuarioStore.ts` | usuarioService | CRUD |
| `companyStore.ts` | companyService | Lectura directa (excepción permitida) |
| `solicitudeStore.ts` | solicitudeService | CRUD |

### 🧩 Componentes compartidos
| Componente | Props | Notas |
|---|---|---|
| `DetalleRecargaModal.vue` | `visible`, `recharge`, `showActions` | Self-contained; emite `approve`/`reject`. `showActions` default `true`. Acciones solo para status 0. |
| `ErrorDialog.vue` | `visible`, `title`, `message`, `details` | Reutilizable para errores de RPC |
| `ConfirmDialog.vue` | `visible`, `message`, `variant` ("danger"\|"primary"), `loading`, `confirm-label` | Emite `confirm`/`cancel` |
| `StatCard.vue` | KPI cards del dashboard | |
| `RecentMovements.vue` | Parent-controlled `load()` | |
| `TripsReport.vue` | Parent-controlled `load()` | |

### 📜 Scripts de Migración (`scripts/`)
| Script | Contenido |
|---|---|
| `migracion_2026-06-15_fix_supervisor_login.sql` | Rol supervisor + helper functions + RPCs filtradas |
| `migracion_2026-06-22_manage_client_email_propagation.sql` | Email propagation en manage_client/manage_unit |
| `migracion_2026-06-24_add_tickets_client.sql` | `add_tickets_to_client` RPC |
| `migracion_2026-06-25_add_search_recharges.sql` | `p_search` en `get_recharges_paginated` |
| `migracion_2026-06-25_add_get_recharge_by_id.sql` | `get_recharge_by_id` RPC |
| `migracion_2026-06-25_stops_and_route_stops.sql` | Tables `stops`/`route_stops` + RPCs `manage_stop`/`get_stops_by_route`/`manage_route_stop` |
| `migracion_2026-08-21_unique_document_id.sql` | `normalize_document_id` SQL function + unique index on normalized `documentID` |
| `migracion_2026-08-21_refactor_company_ticket_to_stop_price.sql` | Script completo: stops + route_stops (tablas, RLS, RPCs) + refactor de `company.ticket` → `route_stops.price` en 4 RPCs + deprecation `charge_ticket` |
| `migracion_2026-08-21_balance_to_money.sql` | Migración modelo contable: conversión de saldos tickets→USD + reescritura de RPCs de cobro/recarga |
| `migracion_2026-08-21_tickets_centralized_rpc.sql` | Centralización de cálculos: helper calculate_tickets_from_amount + reescritura de 3 RPCs (tickets model) |
| `hotfix_manage_profile_password.sql` | Fix `encrypted_password` en manage_profile update |
| `hotfix_manage_profile_insert.sql` | Fix columnas obligatorias en INSERT auth.users |
| `hotfix_delete_user_completo.sql` | Limpieza completa de usuario |
| `cleanup_redundantes_rpc.sql` | Eliminación de RPCs redundantes |
| `cleanup_manage_client_duplicados.sql` | Limpieza de funciones duplicadas |
| `diagnostico_password.sql` | Tabla log para debug de manage_profile |

---

## 🧠 Estado del Contexto: Implementación del Rol Supervisor (2026-06-15)

### 🎯 Goal
Añadir el rol "Supervisor" con los mismos permisos CRUD que el administrador, pero con visibilidad restringida a rutas específicas asignadas.

**Nota**: La migración SQL no se ha ejecutado en Supabase todavía. Todos los cambios están en los archivos canónicos (`supabase_backup_schema.sql`, `supabase_backup_logic.sql`) y empaquetados en `scripts/migracion_2026-06-15_fix_supervisor_login.sql`.

### ✅ Completado — SQL (Estructura + Funciones)
- **`supabase_backup_schema.sql`**: `ALTER TYPE user_role ADD VALUE 'supervisor'`, creación de `user_routes` (user_id ↔ idroute), `ALTER TABLE clients ADD COLUMN idroute`.
- **`supabase_backup_logic.sql`**: 
  - Funciones helper: `is_supervisor()`, `is_admin_or_supervisor()`, `get_current_user_route_ids()`, `get_user_routes()`, `manage_user_routes()`.
  - Login fixes: `get_complete_user_profile` usa `LEFT JOIN clients` con `COALESCE`, `manage_profile` castea `p_user_id::text` en `WHERE uid`.
  - RPCs de recargas con filtro supervisor: `get_recharge_stats`, `get_recharges_paginated` (3 overloads).
  - RPCs de transacciones con filtro supervisor: `get_transactions_paginated`, `get_transactions_export`.
  - RPCs de dashboard con filtro supervisor: `get_dashboard_kpis`, `get_weekly_flow`, `get_recent_movements`.
  - RPCs pre-existentes con `is_admin()`: `manage_route`, `manage_horario`, `manage_route_horario` (ya existían en Supabase).
- **`scripts/migracion_2026-06-15_fix_supervisor_login.sql`**: Script único con 9 secciones (0–9), 16 funciones, ejecución transaccional.

### ✅ Completado — Frontend
- **`authStore.ts`**: `UserRole` incluye `'supervisor'`, login guard acepta `['admin', 'supervisor']`, `isSupervisor` computed, `enforceRoleOrReject()`, `assignedRoutes`/`assignedRouteCount`/`assignedRouteNames`/`fetchAssignedRoutes()`.
- **`usuarioService.ts`**: Tipo `Usuario['role']` incluye `'supervisor'`.
- **`userRouteService.ts`**: Servicio nuevo con `getUserRoutes()` y `assignUserRoutes()`.
- **Router (`src/router/index.ts`)**: Meta `adminOnly: true` en `configuracion`, `info-bancaria`, `carreras`, `usuarios`. Guard `beforeEach` redirige a home si supervisor.
- **`AppLayout.vue`**: Sección Configuración oculta para supervisor (Parámetros, Info. Bancaria, Horarios, Paradas, Rutas, Carreras, Usuarios). Badge "Supervisor · N ruta(s)" en footer.
- **`Clientes.vue`, `Unidades.vue`, `HistorialRecargas.vue`, `HistorialMovimientos.vue`**: Badge "Visibilidad limitada a N ruta(s) asignada(s)".
- **`Usuarios.vue`**: Badge supervisor, selector de perfil, checklist de rutas.

### 📁 Archivos modificados (sesión 2026-06-15)
- `supabase_backup_logic.sql` — helpers + filtros supervisor en todas las RPCs
- `scripts/migracion_2026-06-15_fix_supervisor_login.sql` — script completo (9 secciones)
- `src/router/index.ts` — `adminOnly` en configuracion/horarios/rutas
- `src/layouts/AppLayout.vue` — sección Configuración oculta para supervisor

---

## 🧠 Hotfix: manage_profile — Password no se actualizaba en auth.users (2026-06-15)

**Bug**: `manage_profile` acción `'update'` nunca escribía `encrypted_password` en `auth.users`. Cambiar contraseña desde el panel ejecutaba sin error pero el hash nunca cambiaba, dejando al usuario sin poder loguearse.

### ✅ Fix aplicado
- **SQL (`supabase_backup_logic.sql`, `hotfix_auth_identities.sql`, `migracion_2026-06-15_fix_supervisor_login.sql`)**: Se agregó `encrypted_password = CASE WHEN p_password IS NOT NULL THEN crypt(p_password, gen_salt('bf')) ELSE encrypted_password END` al `UPDATE auth.users` en el branch `'update'`.
- **`scripts/hotfix_manage_profile_password.sql`**: Script standalone con `DROP FUNCTION` de overloads + `CREATE OR REPLACE` con el fix.
- **`scripts/diagnostico_password.sql`**: Script de diagnóstico con tabla de log (`debug_manage_profile`) para capturar parámetros reales de `manage_profile`.
- **`src/services/usuarioService.ts`**: `UsuarioUpdate` incluye `password?: string`. `updateUsuario` usa `input.password || null` en vez de `null` hardcodeado.
- **`src/pages/Usuarios.vue`**: `save()` ahora envía `email` y `password` al editar (antes sólo `name` y `role`).

### 📌 Pendiente
- Ejecutar `scripts/migracion_2026-06-15_fix_supervisor_login.sql` en el SQL Editor de Supabase.
- Verificar login de supervisor, filtros en dashboard/stats/listados, bloqueo de páginas de configuración.

---

## ⚠️ REGLA OBLIGATORIA: INSERT en auth.users desde manage_profile

Cada vez que crees o modifiques la función `manage_profile` (especialmente la acción `'create'`), el `INSERT INTO auth.users` **DEBE incluir obligatoriamente** estas columnas adicionales:

```sql
INSERT INTO auth.users (
    id, instance_id, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_sent_at,
    aud, role, is_sso_user,
    confirmation_token, recovery_token, email_change_token_new, email_change
) VALUES (
    v_auth_id,
    '00000000-0000-0000-0000-000000000000',
    p_email,
    crypt(p_password, gen_salt('bf')),
    NOW(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    json_build_object('sub', v_auth_id, 'user_name', p_name, 'role', p_role, 'email', p_email)::jsonb,
    NOW(), NOW(), NOW(),
    'authenticated', 'authenticated', false,
    '', '', '', ''
);
```

**Razón**: Supabase `auth.users` exige estas columnas explícitamente para evitar errores "Database error querying schema" por esquema incompleto al insertar desde una función `SECURITY DEFINER`.

Archivos canónicos que siempre deben reflejar este cambio:
- `supabase_backup_logic.sql` — fuente de verdad de la función
- `scripts/migracion_2026-06-15_fix_supervisor_login.sql` — script de migración
- Cualquier script hotfix/standalone que contenga `manage_profile`

---

## 🧠 Stops & Route Stops (2026-06-25)

### ✅ Completado — SQL
- **`stops` table**: `id`, `name`, `description`, `status`, `created_at`. PK + index on `name`. RLS: SELECT authenticated, CRUD admin-only.
- **`route_stops` table**: `id`, `route_id` (FK→routes CASCADE), `stop_id` (FK→stops CASCADE), `price` (numeric 10,2), `stop_order`, `created_at`. PK + unique(`route_id`, `stop_id`) + indexes. RLS: SELECT authenticated, CRUD admin-only.
- **RPC `manage_stop`**: list/create/update/delete via `p_action`. Admin-gated after `list`.
- **RPC `get_stops_by_route`**: JOINs `route_stops` + `stops`, ordered by `stop_order`. Authenticated-only.
- **RPC `manage_route_stop`**: list_by_route/create/update/delete/delete_by_route. `ON CONFLICT DO NOTHING`. Admin-gated after `list_by_route`.
- **`scripts/migracion_2026-06-25_stops_and_route_stops.sql`**: Script completo con `DROP POLICY IF EXISTS` + `DROP FUNCTION IF EXISTS` para idempotencia.

### ✅ Completado — Frontend
- **`stopService.ts`**: `Stop`, `StopForm` types; `getStops`, `createStop`, `updateStop`, `deleteStop`.
- **`routeStopService.ts`**: `RouteStop`, `RouteStopForm` types; `getStopsByRoute`, `assignStopToRoute`, `updateRouteStop`, `removeStopFromRoute`.
- **`stopStore.ts`**: Pinia store wrapping stopService.
- **`routeStopStore.ts`**: `stopsByRoute` (Record keyed by route ID), `fetchByRoute`, `assign`, `update`, `remove`, `getStops`.
- **`Stops.vue`**: CRUD completo con desktop table + mobile cards, búsqueda, create/edit dialog, delete confirmation, admin-gated actions.
- **`Rutas.vue`**: Botón "Paradas" (pin_drop icon) en desktop y mobile actions. Dialog con select dropdown (solo no asignadas), reorder (up/down), precio por parada, save con diff incremental (solo INSERT/DELETE/UPDATE de cambios reales).

---

## 🧠 Performance Fix: Post-Login Dashboard Freeze (2026-06-25)

### ✅ Fix aplicado
- **`authStore.ts`**: `login()` setea `initialized = true` inmediatamente. `initAuth()` early-returns si ya está inicializado.
- **`router/index.ts`**: `beforeEach` usa `await new Promise(resolve => setTimeout(resolve, 0))` para yield al event loop antes de `initAuth()`.
- **`Home.vue`**: Flag `ready` + `nextTick()` gate. Muestra skeleton placeholders hasta que datos estén cargados.
- **`RecentMovements.vue` / `TripsReport.vue`**: Loading controlado por el parent via `load()`.

---

## 🧠 Clientes — Photo URL, Email, Tickets y DetalleRecargaModal (2026-06-25)

### ✅ Completado
- **Client types** (`clientService.ts`): `ClientForm` y `Client` incluyen `photo_url?: string`.
- **`get_clients_paginated`**: Solo 7-param overload activa (con `p_idroute`); 3 overloads muertos eliminados. Devuelve `photo_url` y `auth_user_name`.
- **Avatar** en tabla desktop/mobile y en dialog create/edit.
- **Email uniqueness** en `manage_client` (update) y `manage_unit` (update): valida contra `clients`, `auth.users`, `profiles`; propaga cambios a `auth.users` y `profiles`.
- **ErrorDialog** (`ErrorDialog.vue`): Reutilizable con `visible`, `title`, `message`, `details`, botón "Cerrar".
- **Store error capture**: `clientStore.ts` y `unitStore.ts` almacenan mensaje real del error.
- **"Sumar Ticket"**: RPC `add_tickets_to_client`; `ticketsService.addTicketsToClient()`; `ticketStore.addTickets()`; `Clientes.vue` botones + dialogs.
- **`DetalleRecargaModal.vue`**: Self-contained con props `visible`, `recharge`, `showActions` (default true). Emite `approve`/`reject`. `canAct()` solo permite status 0.
- **`getRechargeById`**: RPC + `rechargeService.getRechargeById()` para obtener recarga individual con nombre de cliente y ruta.
- **Clientes.vue Movements**: Desktop table (`hidden md:table`) + mobile cards (`md:hidden`). Botón "Ver detalle" carga recarga completa via `getRechargeById` y abre `DetalleRecargaModal`.
- **Clientes.vue Approve/Reject**: `processRechargeStatus` llamado directamente (no via store). `ConfirmDialog` + `Toast` integrados. `refreshMovements()` re-fetch después de acción.

### 📁 Archivos
- `src/components/DetalleRecargaModal.vue` — modal reutilizable
- `src/components/ErrorDialog.vue` — modal de errores reutilizable
- `src/services/rechargeService.ts` — `getRechargeById`, `processRechargeStatus`
- `src/services/ticketsService.ts` — `getMovimientosUnificado` (retorna `{ history, balance }`)
- `src/pages/Clientes.vue` — photo, email, tickets, movements responsive, approve/reject

---

## 🧠 Recharges Server-Side Search (2026-06-25)

### ✅ Completado
- **`get_recharges_paginated`**: Nuevo parámetro `p_search` (nullable). Matchea `c.name ILIKE`, `r.ref ILIKE`, `r.id::text = p_search`.
- **`HistorialRecargas.vue`**: Input de búsqueda con debounce (300ms). Loading state con skeleton.

---

## 🧠 Unique documentID Validation (2026-08-21)

### ✅ Completado
- **`normalize_document_id(p_value)` SQL function**: STRIP `.`, `-`, `,`, spaces + UPPER. Usado en la creación del cliente.
- **`idx_clients_document_id_unique`**: Unique index on normalized `documentID`.
- **`manage_client` (create)**: Pre-check con `EXISTS` + normaliza el valor antes de insertar.
- **`manage_client` (update)**: Pre-check `AND id != p_id` + normaliza.
- **Frontend `clientService.ts`**: `sanitizeDocumentId()` exportado.
- **`Clientes.vue save()`**: Sanitiza `documentID` antes del submit + catch error 23505 (unique violation).

---

## 🧠 Dual Field: balance (USD) + tickets (2026-08-21)

### 📌 Modelo de negocio
`clients` tiene **dos campos independientes**:
- `balance` (`numeric(10,2)`) → **dinero USD** disponible del cliente.
- `tickets` (`numeric(10,2)`) → **cantidad de tickets** disponibles del cliente.

La conversión entre USD y tickets se hace via `calculate_tickets_from_amount(p_amount_usd)` → `TRUNC(amount / company.ticket, 2)`.

### 📌 Operaciones y fórmulas
| Operación | Fuente | Fórmula RPC |
|---|---|---|
| **Aprobar recarga** | `recharge.amount` (USD) | `balance += amount` AND `tickets += calculate_tickets_from_amount(amount)` |
| **Cobrar viaje** | `ticket_count` (entero) | `charge_usd = qty * company.ticket` → `balance -= charge_usd`, `tickets -= qty` |
| **Sumar saldo manual** | `p_ticket_count` | `tickets += p_ticket_count`, `balance += p_ticket_count * company.ticket` |
| **Rechazar recarga** | — | Sin cambio |
| **Saldo insuficiente** | — | Validado contra `balance` (USD) + `creditLimit` |

### 📌 Función helper centralizada
```sql
calculate_tickets_from_amount(p_amount_usd NUMERIC) → NUMERIC(10,2)
-- Fórmula: TRUNC(p_amount_usd / company.ticket, 2)
-- SECURITY DEFINER. Fuente única de verdad para la conversión USD → tickets.
```

### ✅ RPCs actualizadas (dual write)
- **`process_recharge_status`**: Aprobar → `balance += v_amount` AND `tickets += calculate_tickets_from_amount(v_amount)`. Response incluye `current_client_balance` + `current_client_tickets`.
- **`charge_tickets_bulk`**: Lee `balance` + `tickets`. Calcula `charge_usd = qty * company.ticket`. Descuenta de ambos campos. Response incluye `new_tickets`.
- **`add_tickets_to_client`**: Resuelve `company.ticket`. Suma `p_ticket_count` a `tickets`, suma `p_ticket_count * v_ticket_price` a `balance`. Response incluye `new_tickets`.
- **`charge_ticket` [DEPRECATED]**: Mantenido con dual-write para compatibilidad. Response incluye `tickets`.

### ✅ RPCs de lectura (dual select)
- **`get_client_balance`**: Devuelve `{ balance, tickets }`.
- **`get_client_by_uid`**: Devuelve `balance` + `tickets` directamente (sin computed `tickets_balance`).
- **`get_debtors_list`**: SELECT incluye `tickets`.
- **`get_client_history`**: Response incluye `current_tickets`.
- **`process_payment`**: Response incluye `current_tickets`.
- **`get_clients_paginated`**: SELECT incluye `c.tickets`, sort whitelist incluye `tickets`.
- **`get_complete_user_profile`**: SELECT incluye `c.tickets AS tickets`.

### ✅ Frontend
- **`clientService.ts`**: `Client` e `Debtor` incluyen `tickets: number`.
- **`ticketsService.ts`**: `getSaldoDisponible()` retorna `{ balance, tickets }`. `addTicketsToClient()` retorna `new_tickets`.
- **`ticketStore.ts`**: `tickets = ref(0)`, `cargarBalance` actualiza ambos campos, `resetStore` limpia `tickets`.
- **`Clientes.vue`**: Columnas "SALDO (USD)" + "TICKETS", dialogs muestran ambos campos.
- **`HistorialMovimientos.vue`**: Columna "Monto (USD)" para `transactions.amount`.
- **`DebtorsCard.vue`**: Compatible con `Debtor.tickets`.

### ⚠️ Nota de compatibilidad
- `transactions.amount` almacena el monto USD original de la transacción.
- `recharge.tickets` almacena la cantidad de tickets acreditados.
- Nombres de parámetros RPC (`ticket_count`, `TicketCobroItem.ticket_count`) se mantienen por compatibilidad.

---

## 📌 Pendientes Globales
1. Ejecutar `scripts/migracion_2026-06-15_fix_supervisor_login.sql` en Supabase.
2. Verificar login de supervisor, filtros en dashboard/stats/listados, bloqueo de páginas de configuración.
3. Ejecutar `scripts/migracion_2026-06-25_stops_and_route_stops.sql` en Supabase.
4. Ejecutar `scripts/migracion_2026-08-21_unique_document_id.sql` en Supabase.
5. Ejecutar `scripts/migracion_2026-08-21_refactor_company_ticket_to_stop_price.sql` en Supabase.
6. Ejecutar `scripts/migracion_2026-08-21_tickets_centralized_rpc.sql` en Supabase.
7. Ejecutar `scripts/migracion_2026-08-21_split_balance_tickets.sql` en Supabase.
8. Ejecutar `scripts/migracion_2026-08-21_transactions_dual_fields.sql` en Supabase.
9. Ejecutar `scripts/migracion_2026-09-03_clients_profiles_integridad.sql` en Supabase (unifica: `get_clients_paginated` con nombre resuelto desde profiles, `manage_client` blindado sin writes a `profiles.name`, sync bidireccional SOLO de email vía triggers; sustituye a los borrados 2026-09-01 y 2026-09-02).
