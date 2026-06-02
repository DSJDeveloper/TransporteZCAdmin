-- ============================================================
-- MIGRACIÓN: Agregar columna status a la tabla solicitude
-- ============================================================
-- status: 0 = pendiente, 1 = activa, 2 = cancelada
-- ============================================================

ALTER TABLE solicitude
ADD COLUMN IF NOT EXISTS status INTEGER DEFAULT 0;

-- ============================================================
-- FUNCIÓN RPC: get_pending_solicitude
-- ============================================================
-- Obtiene la solicitud pendiente (status = 0) de hoy para un cliente.
-- Retorna un SETOF solicitude (0 o 1 fila).
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_pending_solicitude(p_idclient INTEGER)
RETURNS SETOF solicitude
LANGUAGE SQL STABLE
AS $$
  SELECT *
  FROM solicitude
  WHERE idclient = p_idclient
    AND date = TO_CHAR(CURRENT_DATE, 'YYYY-MM-DD')
    AND COALESCE(status, 0) = 0
  ORDER BY id DESC
  LIMIT 1;
$$;

-- ============================================================
-- FUNCIÓN RPC: cancel_solicitude
-- ============================================================
-- Cambia el status de una solicitud a 2 (cancelada).
-- Solo permite cancelar si pertenece al cliente y está activa (status = 0).
-- Retorna la fila actualizada o NULL si no encontró coincidencia.
-- ============================================================

CREATE OR REPLACE FUNCTION public.cancel_solicitude(p_id INTEGER, p_idclient INTEGER)
RETURNS solicitude
LANGUAGE SQL
AS $$
  UPDATE solicitude
  SET status = 2
  WHERE id = p_id
    AND idclient = p_idclient
    AND COALESCE(status, 0) = 0
  RETURNING *;
$$;




--Function para procesar el carga de tickets por lote( se usa para el proceso de cobrar)
-- 1. Limpieza preventiva de firmas previas
DROP FUNCTION IF EXISTS public.charge_tickets_bulk(JSONB, INTEGER);

-- 2. Creación del RPC para procesamiento en lote (Bulk)
CREATE OR REPLACE FUNCTION public.charge_tickets_bulk(
    p_transactions JSONB,       -- Array JSON: [{"client_uid": "A1", "ticket_count": 1, "shedule": "08:00 AM"}, ...]
    p_create_by INTEGER         -- ID del usuario/cajero que opera la carga masiva
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER -- Crucial para saltarse las restricciones de RLS en operaciones masivas
AS $$
DECLARE
    v_ticket_price NUMERIC(10,2);
    v_item JSONB;               -- Variable temporal para iterar el array
    
    -- Variables internas para el mapeo de cada registro
    v_client_uid VARCHAR(255);
    v_ticket_count INTEGER;
    v_shedule VARCHAR(255);
    
    -- Variables de procesamiento de negocio
    v_client_id BIGINT;
    v_current_balance NUMERIC(10,2);
    v_credit_limit_raw VARCHAR(255);
    v_credit_limit NUMERIC(10,2);
    v_total_amount_usd NUMERIC(10,2);
    v_new_balance NUMERIC(10,2);
    v_count_booking INTEGER;
    v_tx_uid VARCHAR(255);
    
    -- Contadores y control de respuesta
    v_processed_count INTEGER := 0;
    v_response_data JSONB := '[]'::jsonb; 
BEGIN
    -- 1. 🏢 OBTENER EL PRECIO ACTUAL DEL TICKET (Una sola consulta para todo el lote)
    SELECT ticket INTO v_ticket_price FROM public.company LIMIT 1;

    IF v_ticket_price IS NULL OR v_ticket_price <= 0 THEN
        RETURN json_build_object(
            'success', false,
            'message', 'Error de configuración: El costo del ticket en la tabla company no es válido.'
        );
    END IF;

    -- 2. 🔄 ITERAR EL ARRAY DE TRANSACCIONES ENVIADO DESDE VUE
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_transactions) LOOP
        
        -- Extraer y castear los campos del objeto JSON actual
        v_client_uid := v_item->>'client_uid';
        v_ticket_count := (v_item->>'ticket_count')::INTEGER;
        v_shedule := v_item->>'shedule';

        -- Validar que la data del item no venga corrupta o vacía
        IF v_client_uid IS NULL OR v_ticket_count IS NULL OR v_ticket_count <= 0 THEN
            RAISE EXCEPTION 'Registro inválido en el lote. Verifique UIDs y cantidades de tickets.';
        END IF;

        -- 3. 🔍 BUSCAR Y BLOQUEAR AL CLIENTE (FOR UPDATE evita colisiones si se procesa el mismo cliente en el lote)
        SELECT id, balance, "creditLimit"
        INTO v_client_id, v_current_balance, v_credit_limit_raw
        FROM public.clients
        WHERE uid = v_client_uid
        FOR UPDATE;

        IF v_client_id IS NULL THEN
            -- Forzar aborto total para evitar deudas fantasma
            RAISE EXCEPTION 'El cliente con UID % no existe en el sistema.', v_client_uid;
        END IF;

        -- 4. 🧮 CALCULAR EL MONTO Y VALIDAR LÍMITES
        v_total_amount_usd := v_ticket_count * v_ticket_price;
        v_new_balance := v_current_balance - v_total_amount_usd;
        v_credit_limit := COALESCE(NULLIF(v_credit_limit_raw, '')::NUMERIC, 0.00);

        -- Verificar saldo insuficiente contra límite de crédito
        IF v_new_balance < 0 AND ABS(v_new_balance) > v_credit_limit THEN
            RAISE EXCEPTION 'Transacción rechazada. El cliente con UID % tiene saldo insuficiente (Balance: %, Costo Operación: %, Límite Crédito: %).', 
                v_client_uid, v_current_balance, v_total_amount_usd, v_credit_limit;
        END IF;

        -- 5. 📊 CONTAR BOOKINGS DEL DÍA
        SELECT COUNT(*)::INTEGER INTO v_count_booking
        FROM public.solicitude
        WHERE idclient = v_client_id
          AND date = TO_CHAR(CURRENT_DATE, 'YYYY-MM-DD');

        -- 6. 📝 ACTUALIZAR BALANCE DEL CLIENTE
        UPDATE public.clients
        SET balance = v_new_balance
        WHERE id = v_client_id;

        -- 7. 🆔 GENERAR UID DE TRANSACCIÓN ÚNICA
        v_tx_uid := TO_CHAR(NOW(), 'YYMMDDHH24MISS') || FLOOR(RANDOM() * 100)::TEXT || v_processed_count::TEXT;

        -- 8. 📥 REGISTRAR EN LA TABLA TRANSACTIONS
        INSERT INTO public.transactions (
            uid,
            idclient,
            "createBy",
            amount,
            status,
            shedule,
            "newBalanceClient",
            idunit, 
            created_at
        )
        VALUES (
            v_tx_uid,
            v_client_id,
            p_create_by,
            v_ticket_count::NUMERIC(10,2),
            0, -- Status: 0 = Exitoso
            v_shedule,
            v_new_balance,
            1, -- Unidad por defecto (Ajustar según negocio)
            NOW()
        );

        -- 9. 📌 Acumular información de éxito para el retorno de este cliente específico
        v_response_data := v_response_data || jsonb_build_object(
            'client_uid', v_client_uid,
            'new_balance', v_new_balance,
            'booking_count', v_count_booking
        );

        v_processed_count := v_processed_count + 1;

    END LOOP;

    -- 10. 🎯 RETORNO EXITOSO DE TODO EL LOTE
    RETURN json_build_object(
        'success', true,
        'message', 'Lote de transacciones procesado con éxito.',
        'processed_records', v_processed_count,
        'details', v_response_data
    );

EXCEPTION WHEN OTHERS THEN
    -- 🔥 Ocurrió un error (Saldo insuficiente, cliente no encontrado, etc.)
    -- Postgres hace ROLLBACK de todo el bucle automáticamente aquí.
    RETURN json_build_object(
        'success', false,
        'message', 'Lote cancelado (Rollback ejecutado): ' || SQLERRM,
        'processed_records', 0,
        'details', '[]'::json
    );
END;
$$;

-- 3. Sincronizar API de Supabase
NOTIFY pgrst, 'reload schema';
