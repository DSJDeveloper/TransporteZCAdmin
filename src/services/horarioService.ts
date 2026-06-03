import { supabase } from "./supabaseClient"

export interface Horario {
  id: number
  code: string
  shudle: string
  status: number
}

export type HorarioForm = Omit<Horario, "id">

interface RpcResult<T> {
  success: boolean
  data?: T
  message?: string
}

export async function getHorarios(): Promise<Horario[]> {
  const { data: raw, error } = await supabase.rpc("manage_horario", {
    p_action: "list",
    p_id: null,
    p_code: null,
    p_shudle: null,
    p_status: null,
  })
  if (error) throw error
  const result = raw as unknown as { success: boolean; data?: Horario[]; message?: string }
  if (!result.success) throw new Error(result.message ?? "Error al cargar los horarios")
  return result.data ?? []
}

export async function createHorario(input: HorarioForm): Promise<Horario> {
  const { data: raw, error } = await supabase.rpc("manage_horario", {
    p_action: "create",
    p_id: null,
    p_code: input.code,
    p_shudle: input.shudle,
    p_status: input.status,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<Horario>
  if (!result.success) throw new Error(result.message ?? "Error al crear el horario")
  return result.data as Horario
}

export async function updateHorario(id: number, input: Partial<HorarioForm>): Promise<Horario> {
  const { data: raw, error } = await supabase.rpc("manage_horario", {
    p_action: "update",
    p_id: id,
    p_code: input.code ?? null,
    p_shudle: input.shudle ?? null,
    p_status: input.status ?? null,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<Horario>
  if (!result.success) throw new Error(result.message ?? "Error al actualizar el horario")
  return result.data as Horario
}

export async function deleteHorario(id: number): Promise<void> {
  const { data: raw, error } = await supabase.rpc("manage_horario", {
    p_action: "delete",
    p_id: id,
    p_code: null,
    p_shudle: null,
    p_status: null,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<never>
  if (!result.success) throw new Error(result.message ?? "Error al eliminar el horario")
}
