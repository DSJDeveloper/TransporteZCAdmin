import { supabase } from "./supabaseClient"

export interface RouteHorario {
  id: number
  idroute: number
  idhorario: number
  code: string
  shudle: string
  status: number
}

interface RpcResult<T> {
  success: boolean
  data?: T
  message?: string
}

export async function getHorariosByRoute(idroute: number): Promise<RouteHorario[]> {
  const { data: raw, error } = await supabase.rpc("get_horarios_by_route", {
    p_idroute: idroute,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<RouteHorario[]>
  if (!result.success) throw new Error(result.message ?? "Error al cargar horarios de la ruta")
  return result.data ?? []
}

export async function assignHorarioToRoute(idroute: number, idhorario: number): Promise<void> {
  const { data: raw, error } = await supabase.rpc("manage_route_horario", {
    p_action: "create",
    p_id: null,
    p_idroute: idroute,
    p_idhorario: idhorario,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<never>
  if (!result.success) throw new Error(result.message ?? "Error al asignar horario")
}

export async function removeHorarioFromRoute(relId: number): Promise<void> {
  const { data: raw, error } = await supabase.rpc("manage_route_horario", {
    p_action: "delete",
    p_id: relId,
    p_idroute: null,
    p_idhorario: null,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<never>
  if (!result.success) throw new Error(result.message ?? "Error al remover horario")
}
