#!/bin/bash

# --- CONFIGURACIÓN ---
# Obtén estos datos desde tu Dashboard de Supabase: Project Settings -> Database
DB_USER="postgres"
DB_PASSWORD="TH4QuvnHUu2vl9LA"
DB_HOST="db.vemijoyjpjqcecpugcfy.supabase.co"
DB_PORT="5432"
DB_NAME="postgres"

# Carpeta donde se guardarán los backups
BACKUP_DIR="./backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
FILENAME="$BACKUP_DIR/backup_supabase_$TIMESTAMP.sql"

# Crear directorio si no existe
mkdir -p "$BACKUP_DIR"

# Exportar contraseña para que pg_dump no la pida interactivamente
export PGPASSWORD=$DB_PASSWORD

echo "Iniciando respaldo de la base de datos..."

# Ejecutar pg_dump
# -h: host, -U: usuario, -p: puerto, -d: nombre bd, -F p: formato texto plano
pg_dump -h $DB_HOST -U $DB_USER -p $DB_PORT -d $DB_NAME -F p > "$FILENAME"

# Verificar si el comando fue exitoso
if [ $? -eq 0 ]; then
    echo "Respaldo completado con éxito: $FILENAME"
else
    echo "Error al realizar el respaldo."
    exit 1
fi

# Limpiar variable de entorno
unset PGPASSWORD