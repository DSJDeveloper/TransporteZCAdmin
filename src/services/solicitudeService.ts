import { supabase } from './supabaseClient'

export interface Solicitude {
  id: number
  date: string
  idclient: number
  shedule: string
  route: string | null
  status?: number
}

export interface SolicitudeWithClient extends Solicitude {
  client_name: string
  client_carrer: string | null
  client_document: string | null
  client_phone: string | null
}

export interface SolicitudeInput {
  date: string
  idclient: number
  shedule: string
  route: string | null
}

interface RpcResult<T> {
  success: boolean
  data?: T
  message?: string
}

export const solicitudeService = {
  /**
   * @description Fetches solicitudes filtered by date range with client info.
   * @param {string} dateFrom - Start date (YYYY-MM-DD).
   * @param {string} dateTo - End date (YYYY-MM-DD).
   * @returns {Promise<SolicitudeWithClient[]>} List of solicitudes with client details.
   */
  async getByDateRange(dateFrom: string, dateTo: string): Promise<SolicitudeWithClient[]> {
    const { data, error } = await supabase.rpc('get_solicitudes_by_date_range', {
      p_date_from: dateFrom,
      p_date_to: dateTo,
    })
    if (error) throw error
    return data ?? []
  },

  async getPendingByClient(idclient: number): Promise<Solicitude[]> {
    const { data, error } = await supabase
      .rpc('get_pending_solicitude', { p_idclient: idclient })
    if (error) throw error
    return data ?? []
  },

  async getAll(): Promise<Solicitude[]> {
    const { data: raw, error } = await supabase.rpc("manage_solicitude", {
      p_action: "list",
      p_id: null,
      p_date: null,
      p_idclient: null,
      p_shedule: null,
      p_route: null,
      p_status: null,
    })
    if (error) throw error
    const result = raw as unknown as RpcResult<Solicitude[]>
    if (!result.success) throw new Error(result.message ?? "Error al cargar solicitudes")
    return result.data ?? []
  },

  async getByClient(idclient: number): Promise<Solicitude[]> {
    const { data: raw, error } = await supabase.rpc("manage_solicitude", {
      p_action: "list_by_client",
      p_id: null,
      p_date: null,
      p_idclient: idclient,
      p_shedule: null,
      p_route: null,
      p_status: null,
    })
    if (error) throw error
    const result = raw as unknown as RpcResult<Solicitude[]>
    if (!result.success) throw new Error(result.message ?? "Error al cargar solicitudes")
    return result.data ?? []
  },

  async getById(id: number): Promise<Solicitude | null> {
    const { data: raw, error } = await supabase.rpc("manage_solicitude", {
      p_action: "get_by_id",
      p_id: id,
      p_date: null,
      p_idclient: null,
      p_shedule: null,
      p_route: null,
      p_status: null,
    })
    if (error) throw error
    const result = raw as unknown as RpcResult<Solicitude>
    if (!result.success) return null
    return result.data ?? null
  },

  async create(input: SolicitudeInput): Promise<Solicitude> {
    const { data: raw, error } = await supabase.rpc("manage_solicitude", {
      p_action: "create",
      p_id: null,
      p_date: input.date,
      p_idclient: input.idclient,
      p_shedule: input.shedule,
      p_route: input.route,
      p_status: null,
    })
    if (error) throw error
    const result = raw as unknown as RpcResult<Solicitude>
    if (!result.success) throw new Error(result.message ?? "Error al crear la solicitud")
    return result.data as Solicitude
  },

  async update(id: number, input: Partial<SolicitudeInput>): Promise<Solicitude> {
    const { data: raw, error } = await supabase.rpc("manage_solicitude", {
      p_action: "update",
      p_id: id,
      p_date: input.date ?? null,
      p_idclient: input.idclient ?? null,
      p_shedule: input.shedule ?? null,
      p_route: input.route ?? null,
      p_status: null,
    })
    if (error) throw error
    const result = raw as unknown as RpcResult<Solicitude>
    if (!result.success) throw new Error(result.message ?? "Error al actualizar la solicitud")
    return result.data as Solicitude
  },

  async cancel(id: number, idclient: number): Promise<Solicitude> {
    const { data, error } = await supabase
      .rpc('cancel_solicitude', { p_id: id, p_idclient: idclient })
    if (error) throw error
    if (!data) throw new Error('No se pudo cancelar la solicitud')
    return data as Solicitude
  },

  async remove(id: number): Promise<void> {
    const { data: raw, error } = await supabase.rpc("manage_solicitude", {
      p_action: "delete",
      p_id: id,
      p_date: null,
      p_idclient: null,
      p_shedule: null,
      p_route: null,
      p_status: null,
    })
    if (error) throw error
    const result = raw as unknown as RpcResult<never>
    if (!result.success) throw new Error(result.message ?? "Error al eliminar la solicitud")
  },
}

export default solicitudeService
