import { supabase } from './supabaseClient'

export interface Solicitude {
  id: number
  date: string
  idclient: number
  shedule: string
  route: string | null
  status?: number
}

export interface SolicitudeInput {
  date: string
  idclient: number
  shedule: string
  route: string | null
}

export const solicitudeService = {
  async getPendingByClient(idclient: number): Promise<Solicitude[]> {
    const { data, error } = await supabase
      .rpc('get_pending_solicitude', { p_idclient: idclient })
    if (error) throw error
    return data ?? []
  },

  async getAll(): Promise<Solicitude[]> {
    const { data, error } = await supabase
      .from('solicitude')
      .select('*')
      .order('id', { ascending: false })
    if (error) throw error
    return data ?? []
  },

  async getByClient(idclient: number): Promise<Solicitude[]> {
    const { data, error } = await supabase
      .from('solicitude')
      .select('*')
      .eq('idclient', idclient)
      .order('id', { ascending: false })
    if (error) throw error
    return data ?? []
  },

  async getById(id: number): Promise<Solicitude | null> {
    const { data, error } = await supabase
      .from('solicitude')
      .select('*')
      .eq('id', id)
      .maybeSingle()
    if (error) throw error
    return data
  },

  async create(input: SolicitudeInput): Promise<Solicitude> {
    const { data, error } = await supabase
      .from('solicitude')
      .insert(input)
      .select()
      .maybeSingle()
    if (error) throw error
    if (!data) throw new Error('No se pudo crear la solicitud')
    return data
  },

  async update(id: number, input: Partial<SolicitudeInput>): Promise<Solicitude> {
    const { data, error } = await supabase
      .from('solicitude')
      .update(input)
      .eq('id', id)
      .select()
      .maybeSingle()
    if (error) throw error
    if (!data) throw new Error('No se pudo actualizar la solicitud')
    return data
  },

  async cancel(id: number, idclient: number): Promise<Solicitude> {
    const { data, error } = await supabase
      .rpc('cancel_solicitude', { p_id: id, p_idclient: idclient })
    if (error) throw error
    if (!data) throw new Error('No se pudo cancelar la solicitud')
    return data as Solicitude
  },

  async remove(id: number): Promise<void> {
    const { error } = await supabase
      .from('solicitude')
      .delete()
      .eq('id', id)
    if (error) throw error
  },
}

export default solicitudeService
