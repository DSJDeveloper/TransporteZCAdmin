import { supabase } from "./supabaseClient"

export interface Career {
  id: number
  code: string
  description: string
  status: number
}

export type CareerForm = Omit<Career, "id">

interface RpcResult<T> {
  success: boolean
  data?: T
  message?: string
}

export async function getCareers(): Promise<Career[]> {
  const { data: raw, error } = await supabase.rpc("manage_career", {
    p_action: "list",
    p_id: null,
    p_code: null,
    p_description: null,
    p_status: null,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<Career[]>
  if (!result.success) throw new Error(result.message ?? "Error al cargar las carreras")
  return result.data ?? []
}

export async function getCareersRpc(): Promise<Career[]> {
  const { data: raw, error } = await supabase.rpc("get_careers")
  if (error) throw error
  return (raw ?? []) as Career[]
}

export async function createCareer(input: CareerForm): Promise<Career> {
  const { data: raw, error } = await supabase.rpc("manage_career", {
    p_action: "create",
    p_id: null,
    p_code: input.code,
    p_description: input.description,
    p_status: input.status,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<Career>
  if (!result.success) throw new Error(result.message ?? "Error al crear la carrera")
  return result.data as Career
}

export async function updateCareer(id: number, input: Partial<CareerForm>): Promise<Career> {
  const { data: raw, error } = await supabase.rpc("manage_career", {
    p_action: "update",
    p_id: id,
    p_code: input.code ?? null,
    p_description: input.description ?? null,
    p_status: input.status ?? null,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<Career>
  if (!result.success) throw new Error(result.message ?? "Error al actualizar la carrera")
  return result.data as Career
}

export async function deleteCareer(id: number): Promise<void> {
  const { data: raw, error } = await supabase.rpc("manage_career", {
    p_action: "delete",
    p_id: id,
    p_code: null,
    p_description: null,
    p_status: null,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<never>
  if (!result.success) throw new Error(result.message ?? "Error al eliminar la carrera")
}
