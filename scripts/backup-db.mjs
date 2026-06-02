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
  let sqlLogic = `-- BACKUP: LÓGICA (RPC, RLS, TRIGGERS)\n\n`

  // -----------------------------------------------------
  // 🏗️ ARCHIVO 1: ESQUEMA (CREATE TABLE)
  // -----------------------------------------------------
  console.log('[backup] 🏗️ Extrayendo esquemas de tablas...')
  for (const table of tablesToBackup) {
    const { rows } = await client.query(`
      SELECT 'CREATE TABLE IF NOT EXISTS public.' || table_name || ' (' || 
             string_agg(column_name || ' ' || data_type || 
             COALESCE('(' || character_maximum_length || ')', ''), ', ') || ');' as ddl
      FROM information_schema.columns
      WHERE table_name = $1 AND table_schema = 'public'
      GROUP BY table_name`, [table])
    
    if (rows.length > 0) sqlSchema += rows[0].ddl + '\n\n'
  }

  // -----------------------------------------------------
  // 📦 ARCHIVO 2: DATA
  // -----------------------------------------------------
  console.log('[backup] 📦 Extrayendo registros de tablas...')
  sqlData += `SET session_replication_role = 'replica';\n\n`
  for (const table of tablesToBackup) {
    sqlData += `-- Data para: public.${table}\n`
    const { rows } = await client.query(`SELECT * FROM public.${table}`)
    for (const row of rows) {
      const cols = Object.keys(row).map(c => `"${c}"`).join(', ')
      const vals = Object.values(row).map(v => v === null ? 'NULL' : (typeof v === 'object' ? `'${JSON.stringify(v)}'` : `'${String(v).replace(/'/g, "''")}'`)).join(', ')
      sqlData += `INSERT INTO public.${table} (${cols}) VALUES (${vals});\n`
    }
    sqlData += `\n`
  }
  sqlData += `SET session_replication_role = 'origin';\n`

  // -----------------------------------------------------
  // ⚡ ARCHIVO 3: LÓGICA (RPC, RLS, TRIGGERS)
  // -----------------------------------------------------
  // (Mantiene tu lógica original para funciones, RLS y triggers...)
  // [Se omite el detalle de esta parte por brevedad, usa tu código original aquí]

  // -----------------------------------------------------
  // 💾 ESCRITURA FISICA
  // -----------------------------------------------------
  writeFileSync(resolve(ROOT, 'supabase_backup_schema.sql'), sqlSchema, 'utf-8')
  writeFileSync(resolve(ROOT, 'supabase_backup_data.sql'), sqlData, 'utf-8')
  // writeFileSync(resolve(ROOT, 'supabase_backup_logic.sql'), sqlLogic, 'utf-8')

  console.log('✅ ¡Proceso finalizado!')
} catch (err) {
  console.error(err)
} finally {
  await client.end()
}