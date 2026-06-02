#!/usr/bin/env node

import { readFileSync, existsSync } from 'node:fs'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createInterface } from 'node:readline'

const __dirname = dirname(fileURLToPath(import.meta.url))
const ROOT = resolve(__dirname, '..')
const rl = createInterface({ input: process.stdin, output: process.stdout })

process.env.NODE_ENV ??= 'development'

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
  console.log('[import] .env.local cargado')
}

if (process.env.NODE_ENV === 'production') {
  console.error('[import] ERROR: No se puede ejecutar en produccion.')
  process.exit(1)
}

if (process.env.SUPABASE_IMPORT !== 'true') {
  console.error('[import] ERROR: Debes confirmar la importacion.')
  console.error('[import]   Ejecuta: SUPABASE_IMPORT=true node scripts/import-data.mjs')
  process.exit(1)
}

if (!process.env.SUPABASE_DB_URL) {
  console.error('[import] ERROR: Falta SUPABASE_DB_URL en .env.local')
  console.error('')
  console.error('  1. Ve a: Supabase Dashboard > Project Settings > Database')
  console.error('  2. Copia el "Connection string" (URI) completo')
  console.error('  3. Agregalo en .env.local:')
  console.error('     SUPABASE_DB_URL="postgresql://postgres:password@db.xxxxx.supabase.co:5432/postgres"')
  console.error('')
  process.exit(1)
}

const sqlPath = resolve(ROOT, 'supabase_import.sql')
const sql = readFileSync(sqlPath, 'utf-8')

console.log(`[import] SQL: ${(sql.length / 1024 / 1024).toFixed(2)} MB`)
console.log('')

const answer = await new Promise(r => {
  rl.question('? Importar datos en Supabase (DEV)? [y/N] ', a => r(a.toLowerCase() === 'y'))
})
rl.close()
if (!answer) { console.log('[import] Cancelado.'); process.exit(0) }

let pg
try {
  pg = await import('pg')
} catch {
  console.error('[import] ERROR: Falta el paquete "pg". Instalalo con:')
  console.error('  npm install --save-dev pg')
  process.exit(1)
}

const client = new pg.default.Client({
  connectionString: process.env.SUPABASE_DB_URL,
  ssl: { rejectUnauthorized: false },
})

try {
  await client.connect()
  console.log('[import] Conectado a Supabase\n')
} catch (e) {
  console.error(`[import] ERROR de conexion: ${e.message}`)
  console.error('')
  console.error('  Verifica que SUPABASE_DB_URL en .env.local sea correcto.')
  console.error('  Copialo exactamente desde: Supabase Dashboard > Project Settings > Database')
  process.exit(1)
}

const statements = splitSQL(sql)
console.log(`[import] Ejecutando ${statements.length} sentencias...\n`)

let ok = 0
let err = 0

for (let i = 0; i < statements.length; i++) {
  const stmt = statements[i].trim()
  if (!stmt) continue

  try {
    await client.query(stmt)
    ok++
  } catch (e) {
    err++
    const brief = e.message.slice(0, 150).replace(/\n/g, ' ')
    console.warn(`\n[import] [WARN #${i + 1}] ${brief}`)
  }

  process.stdout.write(`\r[import] ${ok} ok | ${err} err | ${i + 1}/${statements.length}`)
}

console.log(`\n[import] Finalizado: ${ok} ok, ${err} errores`)
await client.end()

function splitSQL(text) {
  const result = []
  let cur = ''
  let inStr = false
  let ch = null
  let i = 0

  while (i < text.length) {
    const c = text[i]
    const n = text[i + 1] || ''

    if (inStr) {
      cur += c
      if (c === '\\' && n === ch) { cur += n; i += 2; continue }
      if (c === ch) inStr = false
      i++; continue
    }

    if (c === "'" || c === '"') { inStr = true; ch = c; cur += c; i++; continue }
    if (c === '-' && n === '-') { while (i < text.length && text[i] !== '\n') i++; cur += '\n'; i++; continue }
    if (c === '/' && n === '*') {
      cur += '/*'; i += 2
      while (i < text.length - 1 && !(text[i] === '*' && text[i+1] === '/')) { cur += text[i]; i++ }
      if (i < text.length - 1) { cur += '*/'; i += 2 }
      continue
    }

    if (c === ';') { result.push(cur.trim()); cur = ''; i++; continue }
    cur += c; i++
  }

  const rem = cur.trim()
  if (rem) result.push(rem)
  return result
}
