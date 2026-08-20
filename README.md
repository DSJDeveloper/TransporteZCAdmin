# transportezc

Transporte Zamprano, esta app es el admin, donde se podra crear, las unidades, editar, o eliminar clientes, usuarios aprobar y rechazar descargas asi como ver los reportes y estadisticas necesarias

## Recommended IDE Setup


Entregables
1. src/pages/HistorialMovimientos.vue
Componente completo con:
- PrimeVue DataTable lazy (lazy, v-model:first, v-model:rows, v-model:sortField, v-model:sortOrder, @page, @sort)
- FiltroRango.vue integrado para filtro de fechas con el evento @filtrar
- Filtros de Unidad y Estatus con <select> que recargan en el servidor al cambiar
- Skeleton loading: filas animadas con animate-pulse mientras carga (en el slot #empty cuando loading=true)
- Paginación custom que replica el diseño del HTML (botones chevron, números, elipsis)
- Formato es-VE: usa formatDateTime y formatCurrency desde formatters.ts
- Estilos: réplica fiel del diseño usando las clases Tailwind del code.html (bento filters, badges, hover states, scrollbar custom)
2. src/services/transactionService.ts
Capa de acceso a datos con:
- Sin select('*'): columnas explícitas id, uid, idclient, createBy, amount, status, created_at, idunit, shedule, newBalanceClient
- Joins a clients(name) y units(name) con normalización (Supabase devuelve arrays, se convierten a objetos)
- Validación de tipos: filtros de fecha validados con regex ISO, idunit validado con Number.isInteger, status validado contra whitelist [0,1,2], sort field contra ALLOWED_COLUMNS Set
- Pag/sort server-side: range(), order() con ascending: boolean
3. src/router/index.ts + src/layouts/AppLayout.vue
- Ruta /movimientos agregada como lazy import
- Sidebar: link "Movimientos" habilitado con swap_horiz icon, usa navClass() para active state
4. rls_transactions.sql
Políticas RLS idempotentes:
- transactions: admins (is_super_admin) ven todo, usuarios regulares solo transacciones donde exista su email en clients
- clients: misma lógica — admins ven todos los clientes (necesario para que el JOIN devuelva nombres)
Estrategia de seguridad (URL tampering)
1. Whitelist de columnas de ordenamiento: ALLOWED_COLUMNS Set en transactionService.ts — si un atacante manipula sortField vía parámetros, se rechaza y se usa created_at por defecto
2. Validación de filtros en backend via Supabase: .gte(), .lte(), .eq() usan parámetros preparados de PostgREST — no hay concatenación de strings SQL
3. Sin select('*'): solo columnas explícitas, reduciendo exposición de datos
4. RLS obligatorio: todas las consultas pasan por el motor de políticas de Supabase — un token anon o de usuario normal no puede escalar a ver datos ajenos aunque manipule la URL
5. Sin RPCs para escritura: la consulta es estrictamente SELECT, no expone mutaciones
Guía RLS
Ejecutar rls_transactions.sql en el SQL Editor de Supabase. La política clave para que el admin vea nombres de clientes es la de clients:
CREATE POLICY "Admins leen todos los clientes, usuarios solo el suyo"
ON public.clients FOR SELECT TO authenticated
USING (
  COALESCE((auth.jwt()->>'is_super_admin')::boolean, false) = true
  OR email = auth.jwt()->>'email'
);
Sin esta política, el JOIN transactions → clients fallaría para filas que no pertenezcan al email del admin, devolviendo clients: null.
▣  Build · Big Pickle · 4m 54s

[VS Code](https://code.visualstudio.com/) + [Vue (Official)](https://marketplace.visualstudio.com/items?itemName=Vue.volar) (and disable Vetur).

## Recommended Browser Setup

- Chromium-based browsers (Chrome, Edge, Brave, etc.):
  - [Vue.js devtools](https://chromewebstore.google.com/detail/vuejs-devtools/nhdogjmejiglipccpnnnanhbledajbpd)
  - [Turn on Custom Object Formatter in Chrome DevTools](http://bit.ly/object-formatters)
- Firefox:
  - [Vue.js devtools](https://addons.mozilla.org/en-US/firefox/addon/vue-js-devtools/)
  - [Turn on Custom Object Formatter in Firefox DevTools](https://fxdx.dev/firefox-devtools-custom-object-formatters/)

## Type Support for `.vue` Imports in TS

TypeScript cannot handle type information for `.vue` imports by default, so we replace the `tsc` CLI with `vue-tsc` for type checking. In editors, we need [Volar](https://marketplace.visualstudio.com/items?itemName=Vue.volar) to make the TypeScript language service aware of `.vue` types.

## Customize configuration

See [Vite Configuration Reference](https://vite.dev/config/).

## Project Setup

```sh
npm install
```

### Compile and Hot-Reload for Development

```sh
npm run dev
```

### Type-Check, Compile and Minify for Production

```sh
npm run build
```
