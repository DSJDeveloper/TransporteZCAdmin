import { supabase } from "./supabaseClient";

// Tipo alineado con la tabla `transactions`
export interface Transaction {
  id: number;
  uid: string;
  idclient: number;
  createBy: number;
  amount: number;
  status: number;
  created_at: string;
  idunit: number;
  shedule: string | null;
  newBalanceClient: number | null;
}
export interface Recharge {
  id: number; // BIGINT
  idclient: number; // INTEGER
  method: string;
  ref?: string | null; // NULLABLE
  picture?: string | null; // NULLABLE
  amount: number; // NUMERIC(10,2)
  tasa?: number | null; // NUMERIC(10,2)
  date: string; // DATE (generalmente se maneja como string 'YYYY-MM-DD')
  status: number; // INTEGER
  createBy?: string | null; // "createBy"
  createAt?: string | null; // "createAt" (TIMESTAMP)
  updateAprobate?: string | null; // "updateAprobate" (TIMESTAMP)
}
export interface Movimiento {
  id: number;
  uid: string;
  type: string;
  idclient: number;
  client: string | null;
  createBy: string;
  amount: number;
  status: number;
  created_at: string;
  date: string;
  idunit: number;
  shedule: string | null;
  newBalanceClient: number | null;
  method: string | null;
  ref: string | null;
  isRecharge: boolean;
}
// Definimos una interfaz limpia para TypeScript
export interface TicketCobroItem {
  client_uid: string;
  ticket_count: number;
  shedule: string;
}
// Servicio para obtener movimientos con filtros de fecha
export const ticketsService = {
  /**
   * Obtiene movimientos y recargas filtrados por cliente y rango de fechas
   * @param idclient ID del cliente (obligatorio)
   * @param fechaInicio Fecha de inicio en formato YYYY-MM-DD
   * @param fechaFin Fecha de fin en formato YYYY-MM-DD
   * @param statusMov Estatus del movimiento
   */
  async getTransaccionesyRechargas(
    idclient: number,
    fechaInicio?: string,
    fechaFin?: string,
    statusMov?: number,
  ) {
    // 1. Llamamos al SP
    const parametros = {
      p_client_id: idclient,
      p_from: fechaInicio
        ? `${fechaInicio.split("T")[0]}T00:00:00`
        : "1900-01-01T00:00:00",
      p_to: fechaFin
        ? `${fechaFin.split("T")[0]}T23:59:59`
        : "2100-12-31T23:59:59",
      p_status: statusMov ?? null,
    };
    //console.log("✈️ Enviando parámetros al SP 'get_client_history':", parametros);
    const { data, error } = await supabase.rpc(
      "get_client_history",
      parametros,
    );

    if (error) throw error;
    return {
      recharges: data.recharges as Recharge[],
      transactions: data.transactions as Transaction[],
      balance: data.total_transactions_amount || 0, // 👈 Aquí capturamos el balance del SP
    };
  },
  /**
   * Obtiene movimientos filtrados por cliente, rango de fecha y/o estatus de la transaccion, tanto de recarga y transacciones u los unifica en un solo model
   * @param idclient ID del cliente (obligatorio)
   * @param fechaInicio Fecha de inicio en formato YYYY-MM-DD
   * @param fechaFin Fecha de fin en formato YYYY-MM-DD
   * @param statusMov Estatus del movimiento
   */
  async getMovimientosUnificado(
    idclient: number,
    fechaInicio?: string,
    fechaFin?: string,
    statusMov?: number,
  ) {
    // 1. Llamamos al SP que nos trae ambos arrays de una vez
    const data = await this.getTransaccionesyRechargas(
      idclient,
      fechaInicio,
      fechaFin,
      statusMov,
    );

    const recharges = (data.recharges || []).map(
      (r: any): Movimiento => ({
        id: r.id,
        uid: "",
        type: "RECHARGE",
        idclient: r.idclient,
        amount: parseFloat(r.amount),
        date: new Date(r.date ?? "1900-01-01T00:00:00").toDateString(),
        status: r.status,
        method: r.method,
        client: null,
        ref: r.ref,
        createBy: r.createBy,
        created_at: r.created_at_formatted,
        idunit: 0,
        shedule: null,
        isRecharge: true,
        newBalanceClient: null,
      }),
    );

    const transactions = (data.transactions || []).map(
      (t: any): Movimiento => ({
        id: t.id,
        type: "TRANSACTION",
        idclient: t.idclient,
        amount: parseFloat(t.amount),
        date: new Date("1900-01-01T00:00:00").toDateString(),
        status: t.status,
        uid: t.uid,
        newBalanceClient: t.newBalanceClient,
        createBy: t.createBy,
        created_at: t.created_at,
        client: t.client,
        idunit: 0,
        shedule: null,
        method: null,
        ref: null,
        isRecharge: false,
      }),
    );

    return {
      history: [...recharges, ...transactions].sort(
        (a, b) => new Date(b.date).getTime() - new Date(a.date).getTime(),
      ),
      balance: data.balance || 0,
    };
  },
  /**
   * Obtiene el saldo disponible del usuario
   */
  async getSaldoDisponible(idclient: number) {
    const { data: raw, error } = await supabase.rpc("get_client_balance", {
      p_client_id: idclient,
    });

    if (error) throw error;
    const result = raw as unknown as { success: boolean; balance?: number; message?: string };
    if (!result.success) throw new Error(result.message ?? "Error al obtener el saldo");

    return result.balance ?? 0;
  },

  async getClienteByUid(uid: string) {
    try {
      const { data, error: rpcError } = await supabase.rpc(
        "get_client_by_uid",
        {
          p_uid: uid,
        },
      );

      if (rpcError) throw rpcError;

      if (data?.success) {
        return data.data; // Retorna exactamente { id, name, balance } para mantener compatibilidad
      } else {
        console.warn(data?.message || "Cliente no encontrado");
        return null;
      }
    } catch (err) {
      console.error("Error en getClienteByUid:", err);
      throw new Error(
        (err as Error).message ||
          "Error al conectar con el servidor de base de datos.",
      );
    }
  },
  /**
   * Obtiene movimientos filtrados por cliente y rango de fechas
   * @param idclient ID del cliente (obligatorio)
   * @param fechaInicio Fecha de inicio en formato YYYY-MM-DD
   * @param fechaFin Fecha de fin en formato YYYY-MM-DD
   * @param statusMov Estatus del movimiento
   */
  async getTransacciones(
    idclient: number,
    fechaInicio?: string,
    fechaFin?: string,
    statusMov?: number,
  ) {
    // 1. Llamamos al SP
    const parametros = {
      p_from: fechaInicio
        ? `${fechaInicio.split("T")[0]}T00:00:00`
        : "1900-01-01T00:00:00",
      p_to: fechaFin
        ? `${fechaFin.split("T")[0]}T23:59:59`
        : "2100-12-31T23:59:59",
      p_client_id: null,
      p_status: statusMov ?? null,
      p_create_by: idclient,
    };
    //console.log("✈️ Enviando parámetros al SP 'get_clients_transactions':", parametros);
    const { data, error } = await supabase.rpc(
      "get_clients_transactions",
      parametros,
    );

    if (error) throw error;
    return {
      transactions: data.transactions as Transaction[],
      balance: data.total_transactions_amount || 0, // 👈 Aquí capturamos el balance del SP
    };
  },
  /**
   * Obtiene movimientos filtrados por cliente, rango de fecha y/o estatus de la transaccion, tanto de recarga y transacciones u los unifica en un solo model
   * @param idclient ID del cliente (obligatorio)
   * @param fechaInicio Fecha de inicio en formato YYYY-MM-DD
   * @param fechaFin Fecha de fin en formato YYYY-MM-DD
   * @param statusMov Estatus del movimiento
   */
  async getMovimientosTransacciones(
    idclient: number,
    fechaInicio?: string,
    fechaFin?: string,
    statusMov?: number,
  ) {
    // 1. Llamamos al SP que nos trae ambos arrays de una vez
    const data = await this.getTransacciones(
      idclient,
      fechaInicio,
      fechaFin,
      statusMov,
    );

    const transactions = (data.transactions || []).map(
      (t: any): Movimiento => ({
        id: t.id,
        type: "TRANSACTION",
        idclient: t.idclient,
        amount: parseFloat(t.amount),
        date: new Date("1900-01-01T00:00:00").toDateString(),
        status: t.status,
        uid: t.uid,
        newBalanceClient: t.newBalanceClient,
        createBy: t.createBy,
        created_at: t.created_at,
        idunit: 0,
        client: t.client_name,
        shedule: null,
        method: null,
        ref: null,
        isRecharge: false,
      }),
    );

    return {
      history: [...transactions].sort(
        (a, b) => new Date(b.date).getTime() - new Date(a.date).getTime(),
      ),
      balance: data.balance || 0,
    };
  },
  /**
   * Ejemplo de llamada a función RPC de PostgreSQL
   * Para procesar un pago o generar un reporte
   */
  async procesarPago(params: {
    clientId: number;
    amount: number;
    method: string; // 'Efectivo', 'Transferencia', etc.
    ref: string | null; // Referencia bancaria opcional
    tasa: number | null; // Tasa de cambio si manejan multimoneda
    date: string; // Formato YYYY-MM-DD
    imageFile: File | null; // Archivo físico capturado del input HTML
    createdBy: string | null; // Usuario que registra la acción
  }) {
    try {
      let uploadedImageUrl = null;

      // 1. Si hay una imagen (capture), la subimos primero a Supabase Storage
      if (params.imageFile) {
        const fileExt = params.imageFile.name.split(".").pop();
        const fileName = `${params.clientId}_${Date.now()}.${fileExt}`;
        const filePath = `recharges/${fileName}`;

        const { error: uploadError } = await supabase.storage
          .from("payments-evidence")
          .upload(filePath, params.imageFile);

        if (uploadError)
          throw new Error(`Error en Storage: ${uploadError.message}`);

        const { data: urlData } = supabase.storage
          .from("payments-evidence")
          .getPublicUrl(filePath);

        uploadedImageUrl = urlData.publicUrl;
      }

      // 2. Ejecutar el Stored Procedure acoplado a la estructura de 'recharge'
      const { data, error: rpcError } = await supabase.rpc("process_payment", {
        p_idclient: params.clientId,
        p_amount: params.amount,
        p_method: params.method,
        p_ref: params.ref || null,
        p_tasa: params.tasa || null,
        p_date: params.date,
        p_picture: uploadedImageUrl, // Mandamos la URL pública guardada en el Storage
        p_create_by: params.createdBy,
      });

      if (rpcError) throw rpcError;

      return data; // Devuelve: { success: true, message, recharge_id, new_balance }
    } catch (err) {
      console.error("Error crítico al procesar la recarga:", err);
      return {
        success: false,
        message:
          (err as Error).message ||
          "Error de conexión con el servidor de bases de datos.",
      };
    }
  },
  async chargeTicketsBulk(
    transactions: Array<{
      client_uid: string;
      ticket_count: number;
      shedule: string;
    }>,
    iddriver: number,
  ) {
    try {
      // 🚀 Invocamos el nuevo RPC pasándole el array completo de objetos
      const { data, error: rpcError } = await supabase.rpc(
        "charge_tickets_bulk",
        {
          p_transactions: transactions,
          p_create_by: iddriver,
        },
      );

      if (rpcError) throw rpcError;

      return data;
    } catch (err) {
      return {
        success: false,
        message:
          (err as Error).message ||
          "Error de conexión con el servidor de bases de datos.",
      };
    }
  },
  /* async procesarPago(monto: number, referencia: string) {
    const { data, error } = await supabase.rpc("process_payment", {
      p_monto: monto,
      p_referencia: referencia,
      p_fecha: new Date().toISOString(),
    });

    if (error) throw error;
    return data;
  },
*/
  async addTicketsToClient(idclient: number, ticketCount: number, createBy: number) {
    const { data, error } = await supabase.rpc("add_tickets_to_client", {
      p_idclient: idclient,
      p_ticket_count: ticketCount,
      p_create_by: createBy,
    })
    if (error) throw error
    return data as { success: boolean; message?: string; new_balance?: number }
  },

  /**
   * Otro ejemplo de RPC para generar reporte diario
   */
  async generarReporteDiario(fecha: string) {
    const { data, error } = await supabase.rpc("generar_reporte_diario", {
      p_fecha: fecha,
    });

    if (error) throw error;
    return data;
  },
};

export default ticketsService;
