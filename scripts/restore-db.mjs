#!/usr/bin/env node

import { existsSync, readdirSync, unlinkSync, readFileSync } from 'node:fs'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execSync } from 'node:child_process'

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

if (!process.env.SUPABASE_DB_URL_TO) {
  console.error('[restore] ❌ ERROR: Falta SUPABASE_DB_URL_TO en .env.local')
  process.exit(1)
}

let pg
try {
  pg = await import('pg')
} catch {
  console.error('[restore] ❌ ERROR: Falta el paquete "pg".')
  process.exit(1)
}

// Rutas de archivos SQL objetivo
const schemaPath = resolve(ROOT, 'supabase_backup_schema.sql')
const dataPath = resolve(ROOT, 'supabase_backup_data.sql')
const logicPath = resolve(ROOT, 'supabase_backup_logic.sql')

let cleanupExtractedFiles = false

// 2. Determinar origen de los archivos (Comprimido vs SQL directos)
let backupFile = process.argv[2]

if (backupFile && backupFile.endsWith('.tar.xz')) {
  const archivePath = resolve(ROOT, backupFile)
  if (!existsSync(archivePath)) {
    console.error(`[restore] ❌ El archivo especificado ${backupFile} no existe.`)
    process.exit(1)
  }
  console.log(`[restore] 📦 Descomprimiendo archivo indicado: ${backupFile}...`)
  execSync(`tar -xJf "${archivePath}" -C "${ROOT}"`, { stdio: 'inherit' })
  cleanupExtractedFiles = true
} else {
  // Buscar el archivo .tar.xz más reciente
  const archives = readdirSync(ROOT)
    .filter(f => f.startsWith('supabase_backup_') && f.endsWith('.tar.xz'))
    .sort()
    .reverse()

  if (archives.length > 0) {
    const latestArchive = archives[0]
    const archivePath = resolve(ROOT, latestArchive)
    console.log(`[restore] 📦 Encontrado archivo comprimido: ${latestArchive}`)
    console.log('[restore] 🗜️ Descomprimiendo...')
    execSync(`tar -xJf "${archivePath}" -C "${ROOT}"`, { stdio: 'inherit' })
    cleanupExtractedFiles = true
  } else {
    console.log('[restore] ℹ️ No se encontraron archivos .tar.xz. Verificando archivos .sql sueltos...')
    
    const hasSchema = existsSync(schemaPath)
    const hasData = existsSync(dataPath)
    const hasLogic = existsSync(logicPath)

    if (!hasSchema && !hasData && !hasLogic) {
      console.error('[restore] ❌ ERROR: No se encontraron respaldos en .tar.xz ni archivos .sql en la raíz.')
      process.exit(1)
    }
    
    console.log('[restore] 📄 Usando archivos .sql existentes directamente en el directorio.')
  }
}

// 3. Conexión y Restauración
const client = new pg.default.Client({
  connectionString: process.env.SUPABASE_DB_URL_TO,
  ssl: { rejectUnauthorized: false },
})

try {
  await client.connect()
  // Helper para ejecutar múltiples sentencias SQL manejando errores individuales
  // Helper rápido: ejecuta bloques completos sin hacer llamadas individuales
  async function runSqlBlock(client, sql, label) {
    if (!sql || !sql.trim()) return
    try {
      await client.query(sql)
    } catch (err) {
      console.warn(`[restore] ⚠️ Error en ${label}: ${err.message.split('\n')[0]}`)
    }
  }

  // Paso 1: Estructura / Esquema (En un solo viaje de red)
  if (existsSync(schemaPath)) {
    console.log('[restore] 🏗️ Restaurando estructura y esquemas...')
    const sqlSchema = readFileSync(schemaPath, 'utf-8')
    await runSqlBlock(client, sqlSchema, 'ESQUEMA')
    console.log('[restore] ✔️ Estructura restaurada.')
  }

  // Paso 2: Datos (En bloques por tabla para máxima velocidad)
  if (existsSync(dataPath)) {
    console.log('[restore] 📦 Restaurando registros de datos...')
    const sqlData = readFileSync(dataPath, 'utf-8')

    // Separamos la data por cada tabla usando el comentario que genera el backup
    const tableBlocks = sqlData.split(/(?=-- Data para: )/g)

    for (const block of tableBlocks) {
      const match = block.match(/-- Data para: (.*)/)
      const tableName = match ? match[1].trim() : 'Bloque de datos'
      
      try {
        await client.query(block)
      } catch (err) {
        console.warn(`[restore] ⚠️ Error al insertar datos en [${tableName}]: ${err.message.split('\n')[0]}`)
      }
    }
    console.log('[restore] ✔️ Datos restaurados.')
  }

  // Paso 3: Lógica (En un solo viaje de red)
  if (existsSync(logicPath)) {
    console.log('[restore] ⚡ Restaurando vistas, funciones, RLS, FKs y triggers...')
    const sqlLogic = readFileSync(logicPath, 'utf-8')
    await runSqlBlock(client, sqlLogic, 'LÓGICA')
    console.log('[restore] ✔️ Lógica restaurada.')
  }

  // Paso 4: Recargar caché de Supabase
  try {
    await client.query(`NOTIFY pgrst, 'reload schema';`)
  } catch {}
  
  // Paso 4: Forzar a Supabase a reconocer las Primary Keys de inmediato
  console.log('[restore] 🔄 Recargando caché de Supabase (PostgREST)...')
  try {
    await client.query(`NOTIFY pgrst, 'reload schema';`)
  } catch {}
  console.log('✅ ¡Restauración completada con éxito!')
} catch (err) {
  console.error('[restore] ❌ Error durante la ejecución del SQL:', err)
} finally {
  try {
    await client.query(`SET session_replication_role = 'origin';`)
  } catch {}
  
  await client.end()

  // 4. Limpieza solo si provienen de una extracción temporal
  if (cleanupExtractedFiles) {
    if (existsSync(schemaPath)) unlinkSync(schemaPath)
    if (existsSync(dataPath)) unlinkSync(dataPath)
    if (existsSync(logicPath)) unlinkSync(logicPath)
    console.log('[restore] 🧹 Archivos temporales .sql eliminados.')
  }
}