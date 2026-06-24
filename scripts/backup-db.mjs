#!/usr/bin/env node

import { writeFileSync, existsSync, readFileSync } from 'node:fs'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const ROOT = resolve(__dirname, '..')

process.env.NODE_ENV ??= 'development'

// 1. Cargar .env.local
const envLocal = resolve(ROOT, '.env.local')
if (existsSync(envLocal)) {
  const content = readFileSync(envLocal, 'utf-8')
  for (const line of content.split('\n')) {
    const t = line.trim()
    if (!t || t.startsWith('#')) continue
    const eq = t.indexOf('=')
    if (eq === -1) continue
    const k = t.slice(0, eq).trim()
    let v = t.slice(eq + 1).trim()
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1)
    if (!process.env[k]) process.env[k] = v
  }
}

if (!process.env.SUPABASE_DB_URL) {
  console.error('[backup] ERROR: Falta SUPABASE_DB_URL en .env.local')
  process.exit(1)
}

let pg
try {
  pg = await import('pg')
} catch {
  console.error('[backup] ERROR: Falta el paquete "pg".')
  process.exit(1)
}

const client = new pg.default.Client({
  connectionString: process.env.SUPABASE_DB_URL,
  ssl: { rejectUnauthorized: false },
})

try {
  await client.connect()
  console.log('[backup] Conectado a Supabase con éxito.')

  //const targetTables = ['company', 'clients', 'users_profiles', 'recharge', 'solicitude', 'transactions', 'units','horario','']
  const { rows: tableRows } = await client.query(`
    SELECT table_name 
    FROM information_schema.tables 
    WHERE table_schema = 'public' 
    AND table_type = 'BASE TABLE'
    AND table_name NOT IN ('schema_migrations', 'users') -- Añade aquí tablas a excluir
  `)
  
  const tablesToBackup = tableRows.map(r => r.table_name)
  console.log(`[backup] Tablas detectadas para exportar: ${tablesToBackup.join(', ')}`)

  const { rows: existingTablesRows } = await client.query(`
    SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'
  `)
  const actualExistingTables = existingTablesRows.map(r => r.table_name)
  //const tablesToBackup = targetTables.filter(t => actualExistingTables.includes(t))

  // Inicializadores de contenido
  let sqlSchema = `-- BACKUP: ESTRUCTURA DE TABLAS\n\n`
  let sqlData = `-- BACKUP: DATA\n\n`
  // -----------------------------------------------------
  // 🧨 LOTE DE DROP TABLES (Al inicio)
  // -----------------------------------------------------
  console.log('[backup] 🧨 Generando lote de eliminación de tablas...')
  sqlSchema += `-- >>> ELIMINACIÓN DE TABLAS <<<\n`
  for (const table of tablesToBackup) {
    sqlSchema += `DROP TABLE IF EXISTS public."${table}" CASCADE;\n`
  }
  sqlSchema += `\n`
// -----------------------------------------------------
  // 🏷️ EXTRACCIÓN DE ENUMS (Tipos personalizados)
  // -----------------------------------------------------
  console.log('[backup] 🏷️ Extrayendo ENUMs...')
  const { rows: enums } = await client.query(`
    SELECT t.typname, 
           string_agg('''' || e.enumlabel || '''', ', ' ORDER BY e.enumsortorder) AS labels
    FROM pg_type t 
    JOIN pg_enum e ON t.oid = e.enumtypid  
    JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace 
    WHERE n.nspname = 'public' 
    GROUP BY t.typname;
  `)
  if (enums.length > 0) {
    sqlSchema += `-- >>> TIPOS ENUM <<<\n`
    for (const en of enums) {
      sqlSchema += `DROP TYPE IF EXISTS public."${en.typname}" CASCADE;\n`
      sqlSchema += `CREATE TYPE public.${en.typname} AS ENUM (${en.labels});\n`
    }
    sqlSchema += `\n`
  }
  // -----------------------------------------------------
  // 🔢 EXTRACCIÓN DE SECUENCIAS
  // -----------------------------------------------------
  console.log('[backup] 🔢 Extrayendo Secuencias...')
  sqlSchema += `-- >>> SECUENCIAS <<<\n`
  
  const { rows: sequences } = await client.query(`
    SELECT sequence_name 
    FROM information_schema.sequences 
    WHERE sequence_schema = 'public'
  `)
  
  if (sequences.length > 0) {
    for (const seq of sequences) {
      // Usamos comillas dobles por si hay mayúsculas en el nombre de la secuencia
      sqlSchema += `CREATE SEQUENCE IF NOT EXISTS public."${seq.sequence_name}";\n`
    }
    sqlSchema += `\n`
  }
// -----------------------------------------------------
  // 🏗️ ARCHIVO 1: ESQUEMA (CREATE TABLE)
  // -----------------------------------------------------
  console.log('[backup] 🏗️ Extrayendo esquemas de tablas...')
  for (const table of tablesToBackup) {
    const { rows } = await client.query(`
      SELECT 'CREATE TABLE IF NOT EXISTS public."' || table_name || '" (' || 
             string_agg(
               '"' || column_name || '" ' || 
               -- Aquí está la corrección: si es USER-DEFINED, usamos el udt_name (el nombre de tu ENUM)
               CASE WHEN data_type = 'USER-DEFINED' THEN '"' || udt_name || '"' ELSE data_type END || 
               COALESCE('(' || character_maximum_length || ')', '') || 
               CASE WHEN is_nullable = 'NO' THEN ' NOT NULL' ELSE '' END || 
               CASE 
                 WHEN is_identity = 'YES' THEN 
                   CASE WHEN identity_generation = 'ALWAYS' THEN ' GENERATED ALWAYS AS IDENTITY' 
                        ELSE ' GENERATED BY DEFAULT AS IDENTITY' END 
                 WHEN column_default IS NOT NULL THEN ' DEFAULT ' || column_default 
                 ELSE '' 
               END, 
               ', '
             ) || ');' as ddl
      FROM information_schema.columns
      WHERE table_name = $1 AND table_schema = 'public'
      GROUP BY table_name`, [table])
    
    if (rows.length > 0) {
      sqlSchema += rows[0].ddl + '\n\n'
    }
  }
// -----------------------------------------------------
  // 🔄 SINCRONIZACIÓN DE SECUENCIAS (Auto-Incrementos)
  // -----------------------------------------------------
  console.log('[backup] 🔄 Generando sincronización de secuencias...')
  sqlData += `-- >>> SINCRONIZACIÓN DE SECUENCIAS <<<\n`
  for (const table of tablesToBackup) {
    sqlData += `
DO $$ 
DECLARE 
  max_id bigint;
  is_ident varchar;
  dtype varchar;
BEGIN
  -- 1. Buscamos si la columna 'id' existe, si es identidad y su TIPO de dato
  SELECT is_identity, data_type INTO is_ident, dtype
  FROM information_schema.columns 
  WHERE table_schema = 'public' 
    AND table_name = '${table}' 
    AND column_name = 'id';

  -- 2. Solo sincronizamos si la columna existe Y es un tipo numérico (evitando UUIDs y textos)
  IF is_ident IS NOT NULL AND dtype IN ('integer', 'bigint', 'smallint') THEN
    
    EXECUTE 'SELECT MAX("id") FROM public."${table}"' INTO max_id;
    
    -- Solo sincronizamos si la tabla tiene datos (max_id no es nulo)
    IF max_id IS NOT NULL THEN
      IF is_ident = 'YES' THEN
        -- Método nativo para columnas IDENTITY (Supabase)
        EXECUTE 'ALTER TABLE public."${table}" ALTER COLUMN "id" RESTART WITH ' || (max_id + 1);
      ELSE
        -- Método clásico para columnas SERIAL
        EXECUTE 'SELECT setval(pg_get_serial_sequence(''public."${table}"'', ''id''), ' || max_id || ')';
      END IF;
    END IF;
    
  END IF;
END $$;\n`;
  }

  sqlData += `\nSET session_replication_role = 'origin';\n`
// -----------------------------------------------------
  // 🔎 EXTRACCIÓN DE ÍNDICES
  // -----------------------------------------------------
  console.log('[backup] 🔎 Extrayendo Índices...')
  sqlSchema += `-- >>> ÍNDICES <<<\n`
  for (const table of tablesToBackup) {
    const { rows: indexes } = await client.query(`
      SELECT indexdef 
      FROM pg_indexes 
      WHERE schemaname = 'public' AND tablename = $1
      AND indexname NOT LIKE '%_pkey' 
    `, [table])
    
    if (indexes.length > 0) {
      for (const idx of indexes) {
        sqlSchema += idx.indexdef + ';\n'
      }
      sqlSchema += '\n'
    }
  }

  // -----------------------------------------------------
  // 📦 ARCHIVO 2: DATA
  // -----------------------------------------------------
  console.log('[backup] 📦 Extrayendo registros de tablas...')
  sqlData += `SET session_replication_role = 'replica';\n\n`
  
  // =====================================================
  // 👤 EXTRACCIÓN ESPECÍFICA: auth.users
  // =====================================================
  console.log('[backup] 👤 Extrayendo registros de auth.users...')
  sqlData += `-- Data para: auth.users\n`
  sqlData += `TRUNCATE TABLE auth.users CASCADE;\n`

  try {
    const { rows: authUsers } = await client.query(`SELECT * FROM auth.users`)
    
    if (authUsers.length === 0) {
      sqlData += `-- (Tabla auth.users vacía)\n\n`
    } else {
      const generatedColumns = ['confirmed_at'];
      const insertableKeys = Object.keys(authUsers[0]).filter(key => !generatedColumns.includes(key));
      const authColumns = insertableKeys.map(col => `"${col}"`).join(', ')
      
      for (const row of authUsers) {
        const values = insertableKeys.map(key => {
          const val = row[key]
          if (val === null) return 'NULL'
          if (val instanceof Date) return `'${val.toISOString()}'`
          if (typeof val === 'object') return `'${JSON.stringify(val).replace(/'/g, "''")}'`
          if (typeof val === 'boolean') return val ? 'TRUE' : 'FALSE'
          if (typeof val === 'number') return val
          return `'${String(val).replace(/'/g, "''")}'`
        }).join(', ')
        sqlData += `INSERT INTO auth.users (${authColumns}) VALUES (${values});\n`
      }
      sqlData += `\n`
    }
  } catch (authErr) {
    console.error('[backup] ⚠️ ADVERTENCIA: No se pudo extraer auth.users:', authErr.message)
    sqlData += `-- ERROR AL EXTRAER AUTH.USERS: ${authErr.message}\n\n`
  }

  // =====================================================
  // 🔑 EXTRACCIÓN ESPECÍFICA: auth.identities
  // =====================================================
  console.log('[backup] 🔑 Extrayendo registros de auth.identities...')
  sqlData += `-- Data para: auth.identities\n`
  sqlData += `TRUNCATE TABLE auth.identities CASCADE;\n`

  try {
    const { rows: authIdentities } = await client.query(`SELECT * FROM auth.identities`)
    
    if (authIdentities.length === 0) {
      sqlData += `-- (Tabla auth.identities vacía)\n\n`
    } else {
      const generatedColumns = ['email'];
      const insertableKeys = Object.keys(authIdentities[0]).filter(key => !generatedColumns.includes(key));
      const identityColumns = insertableKeys.map(col => `"${col}"`).join(', ')
      
      for (const row of authIdentities) {
        const values = insertableKeys.map(key => {
          const val = row[key]
          if (val === null) return 'NULL'
          if (val instanceof Date) return `'${val.toISOString()}'`
          if (typeof val === 'object') return `'${JSON.stringify(val).replace(/'/g, "''")}'`
          if (typeof val === 'boolean') return val ? 'TRUE' : 'FALSE'
          if (typeof val === 'number') return val
          return `'${String(val).replace(/'/g, "''")}'`
        }).join(', ')
        sqlData += `INSERT INTO auth.identities (${identityColumns}) VALUES (${values});\n`
      }
      sqlData += `\n`
    }
  } catch (identitiesErr) {
    console.error('[backup] ⚠️ ADVERTENCIA: No se pudo extraer auth.identities:', identitiesErr.message)
    sqlData += `-- ERROR AL EXTRAER AUTH.IDENTITIES: ${identitiesErr.message}\n\n`
  }

  // =====================================================
  // 🔄 EXTRACCIÓN DE TABLAS PUBLIC (Bucle Unificado y Corregido)
  // =====================================================
  for (const table of tablesToBackup) {
    sqlData += `-- Data para: public."${table}"\n`
    // Se agregan las comillas dobles al table_name
    sqlData += `TRUNCATE TABLE public."${table}" RESTART IDENTITY CASCADE;\n`

    const { rows } = await client.query(`SELECT * FROM public."${table}"`)
    if (rows.length === 0) {
      sqlData += `-- (Tabla vacía)\n\n`; continue
    }

    const columns = Object.keys(rows[0]).map(col => `"${col}"`).join(', ')
    for (const row of rows) {
      const values = Object.keys(row).map(key => {
        const val = row[key]
        if (val === null) return 'NULL'
        if (val instanceof Date) return `'${val.toISOString()}'`
        if (typeof val === 'object') return `'${JSON.stringify(val).replace(/'/g, "''")}'`
        if (typeof val === 'boolean') return val ? 'TRUE' : 'FALSE'
        if (typeof val === 'number') return val
        return `'${String(val).replace(/'/g, "''")}'`
      }).join(', ')
      sqlData += `INSERT INTO public."${table}" (${columns}) VALUES (${values});\n`
    }
    sqlData += `\n`
  }

  // =====================================================
  // 🔄 SINCRONIZACIÓN DE SECUENCIAS (Al final de los inserts)
  // =====================================================
  console.log('[backup] 🔄 Generando sincronización de secuencias...')
  sqlData += `-- >>> SINCRONIZACIÓN DE SECUENCIAS <<<\n`
  for (const table of tablesToBackup) {
    sqlData += `
DO $$ 
DECLARE 
  max_id bigint;
  is_ident varchar;
  dtype varchar;
BEGIN
  SELECT is_identity, data_type INTO is_ident, dtype
  FROM information_schema.columns 
  WHERE table_schema = 'public' 
    AND table_name = '${table}' 
    AND column_name = 'id';

  IF is_ident IS NOT NULL AND dtype IN ('integer', 'bigint', 'smallint') THEN
    EXECUTE 'SELECT MAX("id") FROM public."${table}"' INTO max_id;
    IF max_id IS NOT NULL THEN
      IF is_ident = 'YES' THEN
        EXECUTE 'ALTER TABLE public."${table}" ALTER COLUMN "id" RESTART WITH ' || (max_id + 1);
      ELSE
        EXECUTE 'SELECT setval(pg_get_serial_sequence(''public."${table}"'', ''id''), ' || max_id || ')';
      END IF;
    END IF;
  END IF;
END $$;\n`;
  }

  sqlData += `\nSET session_replication_role = 'origin';\n`

  // -----------------------------------------------------
  // ⚡ ARCHIVO 3: LÓGICA (VISTAS, RPC, RLS, TRIGGERS)
  // -----------------------------------------------------
  let sqlLogic = `-- =====================================================\n`
  sqlLogic += `-- BACKUP: LÓGICA DE SERVIDOR (VISTAS, RPC, RLS, TRIGGERS)\n`
  sqlLogic += `-- Fecha: ${new Date().toISOString()}\n`
  sqlLogic += `-- =====================================================\n\n`

  // -----------------------------------------------------
  // 👁️ EXPORTAR VISTAS (VIEWS)
  // -----------------------------------------------------
  console.log('[backup] 👁️ Extrayendo Vistas...')
  sqlLogic += `-- >>> VISTAS <<<\n\n`
  const { rows: views } = await client.query(`
    SELECT table_name, view_definition
    FROM information_schema.views
    WHERE table_schema = 'public'
  `)
  for (const v of views) {
    sqlLogic += `DROP VIEW IF EXISTS public."${v.table_name}" CASCADE;\n`
    sqlLogic += `CREATE OR REPLACE VIEW public."${v.table_name}" AS \n${v.view_definition};\n\n`
  }

  // -----------------------------------------------------
  // ⚡ EXPORTAR FUNCIONES / RPC
  // -----------------------------------------------------
  console.log('[backup] ⚡ Extrayendo Funciones y RPCs...')
  sqlLogic += `-- >>> FUNCIONES / RPC <<<\n\n`
  const { rows: functions } = await client.query(`
    SELECT routine_name, pg_get_functiondef(p.oid) as definition
    FROM information_schema.routines r
    JOIN pg_proc p ON p.proname = r.routine_name
    WHERE r.specific_schema = 'public' 
      AND r.routine_type = 'FUNCTION'
  `)
  for (const fn of functions) {
    sqlLogic += `-- Función: ${fn.routine_name}\n`
    sqlLogic += `${fn.definition};\n\n`
  }

  // -----------------------------------------------------
  // 🛡️ EXPORTAR POLÍTICAS RLS
  // -----------------------------------------------------
  console.log('[backup] 🛡️ Extrayendo Políticas RLS...')
  sqlLogic += `-- >>> POLÍTICAS DE SEGURIDAD (RLS) <<<\n\n`
  const { rows: policies } = await client.query(`
    SELECT tablename, policyname, cmd, 
           array_to_string(roles, ', ') as roles_string, 
           qual, with_check 
    FROM pg_policies 
    WHERE schemaname = 'public'
  `)
  for (const pol of policies) {
    const targetRoles = pol.roles_string || 'public'
    sqlLogic += `-- Política para: ${pol.tablename}\n`
    sqlLogic += `ALTER TABLE public."${pol.tablename}" ENABLE ROW LEVEL SECURITY;\n`
    sqlLogic += `DROP POLICY IF EXISTS "${pol.policyname}" ON public."${pol.tablename}";\n`
    
    let policyStatement = `CREATE POLICY "${pol.policyname}" ON public."${pol.tablename}" FOR ${pol.cmd} TO ${targetRoles}`;
    if (pol.qual) policyStatement += ` USING (${pol.qual})`;
    if (pol.with_check) policyStatement += ` WITH CHECK (${pol.with_check})`;
    sqlLogic += policyStatement + `;\n\n`;
  }

  // -----------------------------------------------------
  // ⚙️ EXPORTAR TRIGGERS
  // -----------------------------------------------------
  console.log('[backup] ⚙️ Extrayendo Triggers activos...')
  sqlLogic += `-- >>> TRIGGERS <<<\n\n`
  const { rows: triggers } = await client.query(`
    SELECT event_object_schema as schema_name, 
           event_object_table as table_name, 
           trigger_name, 
           action_statement, 
           action_timing, 
           event_manipulation
    FROM information_schema.triggers
    WHERE trigger_schema = 'public' OR event_object_schema = 'auth'
  `)
  for (const tg of triggers) {
    sqlLogic += `-- Trigger: ${tg.trigger_name} sobre ${tg.schema_name}.${tg.table_name}\n`
    sqlLogic += `DROP TRIGGER IF EXISTS ${tg.trigger_name} ON ${tg.schema_name}."${tg.table_name}";\n`
    sqlLogic += `CREATE TRIGGER ${tg.trigger_name} ${tg.action_timing} ${tg.event_manipulation} ON ${tg.schema_name}."${tg.table_name}" FOR EACH ROW ${tg.action_statement};\n\n`
  }

  // -----------------------------------------------------
  // 💾 ESCRITURA FISICA
  // -----------------------------------------------------
  writeFileSync(resolve(ROOT, 'supabase_backup_schema.sql'), sqlSchema, 'utf-8')
  writeFileSync(resolve(ROOT, 'supabase_backup_data.sql'), sqlData, 'utf-8')
  writeFileSync(resolve(ROOT, 'supabase_backup_logic.sql'), sqlLogic, 'utf-8')

  console.log('✅ ¡Proceso finalizado!')
} catch (err) {
  console.error(err)
} finally {
  await client.end()
}