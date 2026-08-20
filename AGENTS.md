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

* **Estructura Base (`supabase_backup_schema.sql`):** * Archivo central de referencia para el esquema de datos. Contiene todas las sentencias `CREATE TABLE`, tipos de datos, llaves primarias/foráneas y restricciones de las tablas del sistema (como `clients`, `recharge`, `transactions`, `company`, `horario`, etc.).
* **Lógica del Servidor y Funciones (`supabase_backup_logic.sql`):** * Archivo central de referencia para la programación en el backend. Contiene todos los Procedimientos Almacenados (RPCs) escritos en PL/pgSQL, triggers, políticas RLS y funciones de control de acceso.


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

### 🗄️ Base de Datos y Formatos de Datos
* **Nombres de Columnas:** Ten cuidado con la tabla `recharge`. Sus columnas usan **camelCase** (`"createAt"`, `"idclient"`, `"createBy"`). En código SQL debes escribirlas entre comillas dobles (ej. `SELECT "createAt" FROM recharge`).
* **Formatos Regionales:** Todas las transformaciones visuales de fechas y monedas deben delegarse a los formateadores de `@/utils/formatters.ts` que utilizan el locale `es-AR`.
* **Exportación de Datos:** Para descargas CSV, utiliza siempre `downloadCSV()` de `@/utils/exportCsv`, la cual inyecta el BOM UTF-8 para garantizar la compatibilidad con Microsoft Excel.


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
- **Router (`src/router/index.ts`)**: Meta `adminOnly: true` en `configuracion`, `info-bancaria`, `horarios`, `rutas`, `usuarios`. Guard `beforeEach` redirige a home si supervisor.
- **`AppLayout.vue`**: Toda la sección Configuración oculta para supervisor (Parámetros, Info. Bancaria, Horarios, Rutas, Usuarios). Badge "Supervisor · N ruta(s)" en footer.
- **`Clientes.vue`, `Unidades.vue`, `HistorialRecargas.vue`, `HistorialMovimientos.vue`**: Badge "Visibilidad limitada a N ruta(s) asignada(s)".
- **`Usuarios.vue`**: Badge supervisor, selector de perfil, checklist de rutas.

### 📁 Archivos modificados (sesión 2026-06-15)
- `supabase_backup_logic.sql` — helpers + filtros supervisor en todas las RPCs
- `scripts/migracion_2026-06-15_fix_supervisor_login.sql` — script completo (9 secciones)
- `src/router/index.ts` — `adminOnly` en configuracion/horarios/rutas
- `src/layouts/AppLayout.vue` — sección Configuración oculta para supervisor

## 🧠 Hotfix: manage_profile — Password no se actualizaba en auth.users (2026-06-15)

**Bug**: `manage_profile` acción `'update'` nunca escribía `encrypted_password` en `auth.users`. Cambiar contraseña desde el panel ejecutaba sin error pero el hash nunca cambiaba, dejando al usuario sin poder loguearse.

### ✅ Fix aplicado
- **SQL (`supabase_backup_logic.sql`, `hotfix_auth_identities.sql`, `migracion_2026-06-15_fix_supervisor_login.sql`)**: Se agregó `encrypted_password = CASE WHEN p_password IS NOT NULL THEN crypt(p_password, gen_salt('bf')) ELSE encrypted_password END` al `UPDATE auth.users` en el branch `'update'`.
- **`scripts/hotfix_manage_profile_password.sql`**: Script standalone con `DROP FUNCTION` de overloads + `CREATE OR REPLACE` con el fix.
- **`scripts/diagnostico_password.sql`**: Script de diagnóstico con tabla de log (`debug_manage_profile`) para capturar parámetros reales de `manage_profile`.
- **`src/services/usuarioService.ts`**: `UsuarioUpdate` incluye `password?: string`. `updateUsuario` usa `input.password || null` en vez de `null` hardcodeado.
- **`src/pages/Usuarios.vue`**: `save()` ahora envía `email` y `password` al editar (antes sólo `name` y `role`).

### Archivos modificados (sesión 2026-06-15 hotfix)
- `supabase_backup_logic.sql` — fix `encrypted_password` en manage_profile
- `hotfix_auth_identities.sql` — mismo fix
- `scripts/migracion_2026-06-15_fix_supervisor_login.sql` — mismo fix
- `scripts/hotfix_manage_profile_password.sql` — nuevo, script standalone del fix
- `scripts/diagnostico_password.sql` — nuevo, script de diagnóstico
- `src/services/usuarioService.ts` — password en UsuarioUpdate/updateUsuario
- `src/pages/Usuarios.vue` — email y password incluidos en update

### 📌 Pendiente
- Ejecutar `scripts/migracion_2026-06-15_fix_supervisor_login.sql` en el SQL Editor de Supabase.
- Verificar login de supervisor, filtros en dashboard/stats/listados, bloqueo de páginas de configuración.

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


https://opncd.ai/share/HTe8r1Xm